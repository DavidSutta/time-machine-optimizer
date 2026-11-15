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
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

NIGHT_START=1        # night window start hour, inclusive (local time)
NIGHT_END=6          # night window end hour, exclusive
NIGHT_MIN_AGE_H=6    # in the window, skip if a backup finished this recently
CATCHUP_AGE_H=26     # outside the window, back up anyway after this many hours
LOGIN_DELAY_S=900    # before a catch-up, wait until the Mac has been up this long
WARN_AGE_H=72        # notify when the last backup is older than this
BREWFILE="$HOME/.config/Brewfile"   # refreshed before each backup; "" to skip

LOG="$HOME/Library/Logs/tm-nightly.log"
WARN_STAMP="$HOME/Library/Logs/tm-nightly.warned"

# Under launchd there's no terminal, so send error messages to the log.
[ -t 2 ] || exec 2>>"$LOG"

MODE="${1:-}"

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

now=$(date +%s)
hour=$((10#$(date +%H)))
if last=$(last_backup_epoch); then
  age_h=$(( (now - last) / 3600 ))
else
  age_h=99999   # no backup found at all
fi

if backup_running; then
  [ "$MODE" = "--dry-run" ] && echo "a backup is already running; nothing to do"
  exit 0
fi

# Warn about stale backups, at most once a day.
if [ "$age_h" -ge "$WARN_AGE_H" ]; then
  if [ ! -f "$WARN_STAMP" ] || [ $(( now - $(stat -f %m "$WARN_STAMP") )) -ge 86400 ]; then
    notify "No backup for ${age_h} hours. Is the backup disk reachable? See ~/Library/Logs/tm-nightly.log"
    [ "$MODE" = "--dry-run" ] || touch "$WARN_STAMP"
  fi
fi

reason=""
if [ "$MODE" = "--now" ]; then
  reason="manual"
elif [ "$hour" -ge "$NIGHT_START" ] && [ "$hour" -lt "$NIGHT_END" ]; then
  [ "$age_h" -ge "$NIGHT_MIN_AGE_H" ] && reason="nightly"
elif [ "$age_h" -ge "$CATCHUP_AGE_H" ]; then
  reason="catch-up"
fi

if [ -z "$reason" ]; then
  [ "$MODE" = "--dry-run" ] && echo "last backup ${age_h}h ago, hour ${hour}: no backup due"
  exit 0
fi

if [ "$MODE" = "--dry-run" ]; then
  echo "last backup ${age_h}h ago, hour ${hour}: would start a ${reason} backup"
  exit 0
fi

# Right after a boot, give the Mac a few minutes before a catch-up backup.
if [ "$reason" = "catch-up" ]; then
  boot=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
  up=$(( now - boot ))
  [ "$up" -lt "$LOGIN_DELAY_S" ] && sleep $(( LOGIN_DELAY_S - up ))
  backup_running && exit 0
fi

# Keep a list of Homebrew packages in the backup, since /opt/homebrew is excluded.
if [ -n "$BREWFILE" ] && command -v brew >/dev/null 2>&1; then
  mkdir -p "$(dirname "$BREWFILE")"
  if HOMEBREW_NO_AUTO_UPDATE=1 brew bundle dump --force --file="$BREWFILE" >/dev/null 2>&1; then
    log "refreshed $BREWFILE"
  else
    log "could not refresh $BREWFILE (continuing)"
  fi
fi

log "starting ${reason} backup (last one ${age_h}h ago)"
if tmutil startbackup --auto --block >> "$LOG" 2>&1; then
  log "backup finished"
else
  log "backup failed (exit $?)"
fi
