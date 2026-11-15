#!/bin/bash
# install.sh: install the nightly Time Machine job for the current user.
#
# Usage: ./install.sh [--uninstall]
#   no option    install, or reinstall after you edit tm-nightly.sh
#   --uninstall  stop the job and remove its files (the log is kept)

set -euo pipefail
cd "$(dirname "$0")"

label=local.tm-nightly
script="$HOME/Library/Scripts/tm-nightly.sh"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

case "${1:-}" in
  ''|--uninstall) ;;
  -h|--help) sed -n '4,6p' "$0" | cut -c3-; exit 0 ;;
  *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
esac

# Stop the job if it's loaded, and wait until launchd has let go of it.
if launchctl print "$domain/$label" >/dev/null 2>&1; then
  launchctl bootout "$domain/$label" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$domain/$label" >/dev/null 2>&1 || break
    sleep 1
  done
fi

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$script" "$plist"
  echo "Removed the nightly job. Its log is still in ~/Library/Logs/tm-nightly.log."
  echo "To back up hourly again, set Back up frequency to Automatically every hour"
  echo "in System Settings > General > Time Machine > Options."
  exit 0
fi

mkdir -p "$(dirname "$script")" "$(dirname "$plist")"
install -m 755 tm-nightly.sh "$script"
install -m 644 "$label.plist" "$plist"
launchctl bootstrap "$domain" "$plist"
echo "Installed. launchd now runs $script every hour and at login."

if [ "$(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2>/dev/null)" = "1" ]; then
  echo
  echo "Time Machine still backs up on its own every hour. To leave backups to this job,"
  echo "set Back up frequency to Manually in System Settings > General > Time Machine > Options."
fi

echo
echo "Right now: $("$script" --dry-run)"
