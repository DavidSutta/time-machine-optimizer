# lib.sh: fake system commands and helpers for the tests. Sourced by run.sh.
#
# The tests run the real scripts, with fake versions of the system commands
# they call. The fakes are exported shell functions, which bash runs instead of
# any program with the same name, so no test can start a real backup, change
# Time Machine settings or show a real notification.
#
# The fakes are controlled through these variables (setup resets them):
#   FAKE_NOW        the current time, in epoch seconds (set it with `at`)
#   FAKE_SNAPSHOTS  completion times of the backups, oldest first ("" = none)
#   FAKE_DEFAULTS   "fail" makes reading Time Machine's settings fail
#   FAKE_BOOT       boot time, in epoch seconds (0 = up for a long time)
#   FAKE_BREW       "fail" makes saving the Brewfile fail
#   FAKE_BACKUP_EXIT               exit code of `tmutil startbackup`
#   FAKE_BACKUP_STARTS_DURING_WAIT "1" starts a backup while the job waits
# The fakes record what they were asked to do in $STATE/calls and
# $STATE/notifications.

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# --- Fake system commands ---------------------------------------------------

# `date +FORMAT` prints the fake time; other uses (parsing dates) run normally.
date() {
  case "${1:-}" in
    +*) command date -r "$FAKE_NOW" "$@" ;;
    *)  command date "$@" ;;
  esac
}

# `defaults export /Library/Preferences/com.apple.TimeMachine FILE` writes a
# settings file with the fake backup times and the paths in $STATE/skip_paths.
defaults() {
  [ "${1:-}" = export ] && [ "${FAKE_DEFAULTS:-ok}" = ok ] || return 1
  local d p
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo '<key>Destinations</key><array><dict><key>SnapshotDates</key><array>'
    for d in ${FAKE_SNAPSHOTS:-}; do echo "<date>$d</date>"; done
    echo '</array></dict></array>'
    echo '<key>SkipPaths</key><array>'
    while IFS= read -r p; do echo "<string>$p</string>"; done < "$STATE/skip_paths"
    echo '</array>'
    echo '</dict></plist>'
  } > "$3"
}

tmutil() {
  local cmd="${1:-}" p
  case "$cmd" in
    status)
      printf '{\n    Running = %s;\n}\n' "$(cat "$STATE/running")" ;;
    startbackup)
      echo "tmutil $*" >> "$STATE/calls"
      return "${FAKE_BACKUP_EXIT:-0}" ;;
    addexclusion|removeexclusion)
      shift
      [ "${1:-}" = -p ] && shift
      for p in "$@"; do echo "$cmd $p" >> "$STATE/calls"; done ;;
    *)
      echo "tmutil $* (unexpected)" >> "$STATE/calls"
      return 1 ;;
  esac
}

osascript() { echo "$*" >> "$STATE/notifications"; }

sysctl() { echo "{ sec = ${FAKE_BOOT:-0}, usec = 0 } Thu Jan  1 00:00:00 1970"; }

sleep() {
  echo "sleep $*" >> "$STATE/calls"
  [ "${FAKE_BACKUP_STARTS_DURING_WAIT:-}" = 1 ] && echo 1 > "$STATE/running"
  return 0
}

# `brew bundle dump --file=PATH` writes a one-line Brewfile.
brew() {
  local a
  echo "brew $*" >> "$STATE/calls"
  if [ "${FAKE_BREW:-ok}" != ok ]; then
    echo "Error: fake brew failure" >&2
    return 1
  fi
  for a in "$@"; do
    case "$a" in --file=*) echo 'brew "git"' > "${a#--file=}" ;; esac
  done
}

sudo() { "$@"; }

export -f date defaults tmutil osascript sysctl sleep brew sudo

# --- Setup ------------------------------------------------------------------

# Fresh fake home folder and state for one test. $T is the test's folder.
setup() {
  T="$TEST_ROOT/$1"
  STATE="$T/state"
  export HOME="$T/home" STATE TZ=UTC
  mkdir -p "$HOME/Library/Logs" "$STATE"
  echo 0 > "$STATE/running"
  : > "$STATE/calls"
  : > "$STATE/notifications"
  : > "$STATE/skip_paths"
  unset FAKE_DEFAULTS FAKE_BREW FAKE_BACKUP_EXIT FAKE_BACKUP_STARTS_DURING_WAIT
  export FAKE_BOOT=0

  # A copy of the job whose PATH holds system tools only, so the real Homebrew
  # is never found: `brew` is then the fake above, or missing after `no_brew`.
  sed -E 's|^export PATH=.*|export PATH="/usr/bin:/bin:/usr/sbin:/sbin"|' \
    "$REPO/tm-nightly.sh" > "$T/tm-nightly.sh"

  at "2026-11-16 12:00"
  last_backup_ago 1
}

# Change one setting in the test's copy of tm-nightly.sh.
setting() {
  sed -i '' -E "s|^$1=[^ ]*|$1=$2|" "$T/tm-nightly.sh"
  grep -q "^$1=$2" "$T/tm-nightly.sh" || fail "could not change setting $1"
}

no_brew() { unset -f brew; }

# --- Time -------------------------------------------------------------------

iso() { command date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# at "YYYY-MM-DD HH:MM[:SS]": set the fake clock (UTC).
at() {
  local t="$1"
  [ ${#t} -eq 16 ] && t="$t:00"
  FAKE_NOW=$(command date -j -u -f '%Y-%m-%d %H:%M:%S' "$t" +%s) || fail "bad time: $1"
  export FAKE_NOW
}

# last_backup_ago HOURS: the newest backup finished HOURS before the fake
# clock. An older backup a week before it is listed too.
last_backup_ago() {
  local t=$(( FAKE_NOW - $1 * 3600 ))
  export FAKE_SNAPSHOTS="$(iso $(( t - 7 * 86400 ))) $(iso "$t")"
}

no_backups() { export FAKE_SNAPSHOTS=""; }

backup_in_progress() { echo 1 > "$STATE/running"; }

# --- Running and checking ---------------------------------------------------

# run_job [OPTION]: run the job once. Its output goes to $T/out.
run_job() { /bin/bash "$T/tm-nightly.sh" "$@" > "$T/out" 2>&1; }

# Clear what the fakes recorded, between runs within one test.
forget_calls() { : > "$STATE/calls"; : > "$STATE/notifications"; }

count() {
  [ -f "$2" ] || { echo 0; return; }
  grep -c -- "$1" "$2" || true
}
backups()       { count '^tmutil startbackup' "$STATE/calls"; }
notifications() { count 'display notification' "$STATE/notifications"; }
job_log()       { cat "$HOME/Library/Logs/tm-nightly.log" 2>/dev/null; }

fail() { echo "  FAIL: $*"; exit 1; }

# expect WHAT ACTUAL EXPECTED
expect() { [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"; }

# expect_text WHAT TEXT SNIPPET / expect_no_text WHAT TEXT SNIPPET
expect_text()    { case "$2" in *"$3"*) ;; *) fail "$1 should contain '$3', got: $2" ;; esac; }
expect_no_text() { case "$2" in *"$3"*) fail "$1 should not contain '$3', got: $2" ;; esac; }
