#!/bin/bash
# tm-nightly.sh: run one Time Machine backup per night, and catch up after
# nights the Mac was turned off.
#
# launchd runs this every hour on the hour and at login
# (~/Library/LaunchAgents/local.tm-nightly.plist). Each run decides:
#   - inside the night window: back up unless a backup finished recently
#   - outside it: back up only if a night was missed (last backup too old)
#   - if nothing has backed up for WARN_AGE_H: show a notification, once a day
#
# Usage: tm-nightly.sh [--dry-run | --now]
#   --dry-run  print what it would do and change nothing
#   --now      start a backup right away (to test the setup)

set -u
# System tools first, so a GNU `date` or `sed` from Homebrew can't shadow them.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

NIGHT_START=1        # night window start hour, inclusive (local time)
NIGHT_END=6          # night window end hour, exclusive; may cross midnight (22 and 6)
NIGHT_MIN_AGE_H=6    # in the window, skip if a backup finished this recently
CATCHUP_AGE_H=26     # outside the window, back up anyway after this many hours
LOGIN_DELAY_S=900    # before a catch-up, wait until the Mac has been up this long
WARN_AGE_H=72        # notify when the last backup is older than this
BREWFILE="$HOME/.config/Brewfile"   # Homebrew package list, saved before each backup; "" to skip

LOG="$HOME/Library/Logs/tm-nightly.log"
WARN_STAMP="$HOME/Library/Logs/tm-nightly.warned"   # time of the last stale-backup notification
WARN_GAP_S=$(( 86400 - 600 ))   # one day, minus slack so the notification keeps its time of day

MODE="${1:-}"
case "$MODE" in
  ''|--dry-run|--now) ;;
  -h|--help) sed -n '11,13p' "$0" | cut -c3-; exit 0 ;;
  *) echo "unknown option: $MODE (see --help)" >&2; exit 2 ;;
esac

# Under launchd there's no terminal, so send error messages to the log
# (except for a dry run, which writes nothing).
[ -t 2 ] || [ "$MODE" = "--dry-run" ] || exec 2>>"$LOG"

log() {
  if [ "$MODE" = "--dry-run" ]; then
    echo "$*"
    return
  fi
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
  [ "$MODE" = "--now" ] && echo "$*"
}

notify() {
  if [ "$MODE" = "--dry-run" ]; then
    echo "would notify: $1"
    return
  fi
  osascript -e "display notification \"$1\" with title \"Time Machine\"" >/dev/null 2>&1
}

# Completion time of the newest backup on the destination, in epoch seconds.
# The prefs file isn't readable directly, so read it through `defaults export`.
last_backup_epoch() {
  local tmp n d=""
  tmp=$(mktemp -t tm-nightly) || return 1
  defaults export /Library/Preferences/com.apple.TimeMachine "$tmp" 2>/dev/null
  n=$(plutil -extract Destinations.0.SnapshotDates raw -o - "$tmp" 2>/dev/null)
  case "$n" in
    ''|*[!0-9]*) ;;
    *) [ "$n" -gt 0 ] && d=$(plutil -extract "Destinations.0.SnapshotDates.$((n - 1))" raw -o - "$tmp" 2>/dev/null) ;;
  esac
  rm -f "$tmp"
  [ -n "$d" ] || return 1
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$d" +%s 2>/dev/null
}

backup_running() { tmutil status 2>/dev/null | grep -q 'Running = 1'; }

# Whether an hour of the day falls in the night window, which may cross midnight.
in_night_window() {
  if [ "$NIGHT_START" -le "$NIGHT_END" ]; then
    [ "$1" -ge "$NIGHT_START" ] && [ "$1" -lt "$NIGHT_END" ]
  else
    [ "$1" -ge "$NIGHT_START" ] || [ "$1" -lt "$NIGHT_END" ]
  fi
}

now=$(date +%s)
hour=$((10#$(date +%H)))
if last=$(last_backup_epoch); then
  age_h=$(( (now - last) / 3600 ))
  age_text="${age_h}h ago"
else
  age_h=99999   # no backup found: treat it as very old
  age_text="none found"
fi

if backup_running; then
  [ "$MODE" = "--dry-run" ] && echo "a backup is already running; nothing to do"
  exit 0
fi

# Warn about stale backups, at most once a day.
if [ "$age_h" -ge "$WARN_AGE_H" ]; then
  last_warn=$(cat "$WARN_STAMP" 2>/dev/null)
  case "$last_warn" in ''|*[!0-9]*) last_warn=0 ;; esac
  if [ $(( now - last_warn )) -ge "$WARN_GAP_S" ]; then
    if [ "$age_text" = "none found" ]; then
      msg="No Time Machine backup found."
    else
      msg="No backup for ${age_h} hours."
    fi
    notify "$msg Is the backup disk reachable? See ~/Library/Logs/tm-nightly.log"
    [ "$MODE" = "--dry-run" ] || echo "$now" > "$WARN_STAMP"
  fi
fi

reason=""
if [ "$MODE" = "--now" ]; then
  reason="manual"
elif in_night_window "$hour"; then
  [ "$age_h" -ge "$NIGHT_MIN_AGE_H" ] && reason="nightly"
elif [ "$age_h" -ge "$CATCHUP_AGE_H" ]; then
  reason="catch-up"
fi

if [ -z "$reason" ]; then
  [ "$MODE" = "--dry-run" ] && echo "last backup: ${age_text}, hour ${hour}: no backup due"
  exit 0
fi

if [ "$MODE" = "--dry-run" ]; then
  echo "last backup: ${age_text}, hour ${hour}: would start a ${reason} backup"
  exit 0
fi

# Right after a boot, give the Mac a few minutes before a catch-up backup.
if [ "$reason" = "catch-up" ]; then
  boot=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
  up=$(( now - boot ))
  [ "$up" -lt "$LOGIN_DELAY_S" ] && sleep $(( LOGIN_DELAY_S - up ))
  backup_running && exit 0
fi

# If Homebrew is installed, save the package list, so the backup holds what's
# needed to reinstall the packages (/opt/homebrew itself can then be excluded).
# A failure here gets a notification but doesn't stop the backup.
if [ -n "$BREWFILE" ] && command -v brew >/dev/null 2>&1; then
  mkdir -p "$(dirname "$BREWFILE")"
  if HOMEBREW_NO_AUTO_UPDATE=1 brew bundle dump --force --file="$BREWFILE" >/dev/null 2>>"$LOG"; then
    log "saved the Homebrew package list to $BREWFILE"
  else
    log "could not save the Homebrew package list to $BREWFILE; backing up anyway"
    notify "Couldn't save the Homebrew package list. The backup runs anyway. See ~/Library/Logs/tm-nightly.log"
  fi
fi

log "starting ${reason} backup (last backup: ${age_text})"
tmutil startbackup --auto --block >> "$LOG" 2>&1
status=$?
if [ "$status" -eq 0 ]; then
  log "backup finished"
else
  log "backup failed (exit $status)"
fi
