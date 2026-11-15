# Tests for exclude.sh, run against a list file in the test's folder.

run_exclude() { /bin/bash "$REPO/exclude.sh" "$@" > "$T/out" 2>&1; }

status_line() { printf '%-16s %s' "$1" "$2"; }

# A list with comments, a blank line, trailing spaces and no final newline:
# one folder to exclude, one already excluded, one this Mac doesn't have.
sample_list() {
  mkdir -p "$HOME/new folder" "$HOME/excluded"
  echo "$HOME/excluded" > "$STATE/skip_paths"
  printf '%s\n' '# a comment' '   # an indented comment' '' '~/new folder   ' '~/excluded' > "$T/list.txt"
  printf '%s' '~/missing' >> "$T/list.txt"
}

test_exclude_preview_shows_each_status() {
  sample_list
  run_exclude "$T/list.txt"
  expect "exit code" "$?" 0
  expect_text "output" "$(cat "$T/out")" "$(status_line 'backed up' "$HOME/new folder")"
  expect_text "output" "$(cat "$T/out")" "$(status_line 'excluded' "$HOME/excluded")"
  expect_text "output" "$(cat "$T/out")" "$(status_line 'not on this Mac' "$HOME/missing")"
  expect "folders listed" "$(grep -cF "$HOME/" "$T/out")" 3
  expect "tmutil calls" "$(cat "$STATE/calls")" ""
}

test_exclude_apply_adds_only_new_folders() {
  sample_list
  run_exclude --apply "$T/list.txt"
  expect "tmutil calls" "$(cat "$STATE/calls")" "addexclusion $HOME/new folder"
}

test_exclude_remove_puts_back_only_excluded_folders() {
  sample_list
  run_exclude --remove "$T/list.txt"
  expect "tmutil calls" "$(cat "$STATE/calls")" "removeexclusion $HOME/excluded"
}

test_exclude_apply_with_nothing_new() {
  mkdir -p "$HOME/excluded"
  echo "$HOME/excluded" > "$STATE/skip_paths"
  echo '~/excluded' > "$T/list.txt"
  run_exclude --apply "$T/list.txt"
  expect "exit code" "$?" 0
  expect_text "output" "$(cat "$T/out")" "Nothing to exclude."
  expect "tmutil calls" "$(cat "$STATE/calls")" ""
}

test_exclude_rejects_unknown_option() {
  run_exclude --aply
  expect "exit code" "$?" 2
  expect "tmutil calls" "$(cat "$STATE/calls")" ""
}

test_shipped_list_has_only_full_paths() {
  local bad
  bad=$(grep -v '^[[:space:]]*#' "$REPO/exclusions.txt" | grep -v '^[[:space:]]*$' | grep -v -e '^~/' -e '^/' || true)
  expect "entries not starting with ~/ or /" "$bad" ""
  run_exclude "$REPO/exclusions.txt"
  expect "exit code" "$?" 0
  expect "tmutil calls" "$(cat "$STATE/calls")" ""
}
