#!/bin/bash
# exclude.sh: leave the folders listed in exclusions.txt out of Time Machine.
#
# Usage: ./exclude.sh [--apply | --remove] [list file]
#   no option  show each folder's status and change nothing
#   --apply    exclude the listed folders (asks for your password)
#   --remove   put the listed folders back into backups (asks for your password)
#
# Folders are excluded by path (tmutil addexclusion -p), so the exclusion stays
# even if an app deletes and recreates the folder.

set -euo pipefail

mode=preview
case "${1:-}" in
  --apply)   mode=apply; shift ;;
  --remove)  mode=remove; shift ;;
  -h|--help) sed -n '4,7p' "$0" | cut -c3-; exit 0 ;;
  -*)        echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
esac
list="${1:-$(dirname "$0")/exclusions.txt}"

# Paths Time Machine already excludes by path, one per line. The settings file
# isn't readable directly, so read it through `defaults export`.
excluded_now() {
  local tmp n i=0
  tmp=$(mktemp -t exclude) || return 0
  defaults export /Library/Preferences/com.apple.TimeMachine "$tmp" 2>/dev/null || true
  n=$(plutil -extract SkipPaths raw -o - "$tmp" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  while [ "$i" -lt "$n" ]; do
    plutil -extract "SkipPaths.$i" raw -o - "$tmp" 2>/dev/null || true
    echo
    i=$((i + 1))
  done
  rm -f "$tmp"
}
current=$(excluded_now)

to_add=()
to_remove=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"   # trim leading spaces
  line="${line%"${line##*[![:space:]]}"}"   # trim trailing spaces
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in '~'|'~/'*) line="$HOME${line#\~}" ;; esac

  if grep -Fxq -- "$line" <<< "$current"; then
    status="excluded"
    to_remove+=("$line")
  elif [ -e "$line" ]; then
    status="backed up"
    to_add+=("$line")
  else
    status="not on this Mac"
  fi
  printf '%-16s %s\n' "$status" "$line"
done < "$list"
echo

case "$mode" in
  preview)
    echo "${#to_add[@]} folder(s) to exclude. Run '$0 --apply' to exclude them."
    ;;
  apply)
    if [ "${#to_add[@]}" -eq 0 ]; then
      echo "Nothing to exclude."
      exit 0
    fi
    sudo tmutil addexclusion -p "${to_add[@]}"
    echo "Excluded ${#to_add[@]} folder(s)."
    ;;
  remove)
    if [ "${#to_remove[@]}" -eq 0 ]; then
      echo "Nothing to put back."
      exit 0
    fi
    sudo tmutil removeexclusion -p "${to_remove[@]}"
    echo "Put ${#to_remove[@]} folder(s) back into backups."
    ;;
esac
