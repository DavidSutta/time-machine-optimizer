# Tests for tm-nightly.sh. Each test starts from `setup` in lib.sh: the clock at
# 2026-11-16 12:00 (outside the night window), the last backup 1 hour old,
# Homebrew installed, and the default settings.

# Hours (00-23) at which the job starts a backup when the last one is HOURS old.
backup_hours() {
  local h hours=""
  for h in $(seq -w 0 23); do
    at "2026-11-16 $h:00"
    last_backup_ago "$1"
    forget_calls
    run_job
    [ "$(backups)" = 1 ] && hours="$hours $h"
  done
  echo "${hours# }"
}

# --- Stale-backup notification ----------------------------------------------

test_stale_backup_notifies_once_a_day() {
  export FAKE_BACKUP_EXIT=1   # backups keep failing
  last_backup_ago 80
  run_job
  expect "notifications after the first run" "$(notifications)" 1
  expect_text "notification" "$(cat "$STATE/notifications")" "No backup for 80 hours."
  at "2026-11-16 13:00"; run_job
  at "2026-11-16 23:00"; run_job
  at "2026-11-17 03:00"; run_job
  expect "notifications later that day" "$(notifications)" 1
}

test_stale_backup_notifies_again_next_day() {
  export FAKE_BACKUP_EXIT=1
  last_backup_ago 80
  run_job
  at "2026-11-17 11:00"; run_job
  expect "notifications 23 hours later" "$(notifications)" 1
  at "2026-11-17 12:00"; run_job
  expect "notifications 24 hours later" "$(notifications)" 2
  expect_text "second notification" "$(tail -1 "$STATE/notifications")" "No backup for 104 hours."
}

test_next_day_notification_keeps_its_time_of_day() {
  export FAKE_BACKUP_EXIT=1
  last_backup_ago 80
  at "2026-11-16 12:00:05"; run_job
  at "2026-11-17 12:00:00"; run_job   # a few seconds short of 24 hours
  expect "notifications" "$(notifications)" 2
}

test_no_notification_until_warn_age() {
  last_backup_ago 71
  run_job
  expect "notifications at 71 hours" "$(notifications)" 0
  forget_calls
  last_backup_ago 72
  run_job
  expect "notifications at 72 hours" "$(notifications)" 1
}

# --- When backups start -----------------------------------------------------

test_window_skips_when_a_backup_is_recent() {
  at "2026-11-16 03:00"
  last_backup_ago 5
  run_job
  expect "backups with the last one 5h old" "$(backups)" 0
  last_backup_ago 6
  run_job
  expect "backups with the last one 6h old" "$(backups)" 1
  expect_text "log" "$(job_log)" "starting nightly backup"
}

test_catchup_outside_window_when_overdue() {
  last_backup_ago 25
  run_job
  expect "backups with the last one 25h old" "$(backups)" 0
  last_backup_ago 26
  run_job
  expect "backups with the last one 26h old" "$(backups)" 1
  expect_text "log" "$(job_log)" "starting catch-up backup"
}

test_scheduled_backups_only_in_window() {
  expect "hours with a backup" "$(backup_hours 7)" "01 02 03 04 05"
}

test_window_can_cross_midnight() {
  setting NIGHT_START 22
  setting NIGHT_END 6
  expect "hours with a backup" "$(backup_hours 7)" "00 01 02 03 04 05 22 23"
}

test_nothing_happens_while_a_backup_runs() {
  backup_in_progress
  last_backup_ago 80
  run_job
  expect "backups" "$(backups)" 0
  expect "notifications" "$(notifications)" 0
}

test_no_backup_history_backs_up_and_notifies() {
  no_backups
  run_job
  expect "backups" "$(backups)" 1
  expect_text "notification" "$(cat "$STATE/notifications")" "No Time Machine backup found."
  expect_no_text "notification" "$(cat "$STATE/notifications")" "99999"
  expect_text "log" "$(job_log)" "last backup: none found"
}

test_unreadable_settings_count_as_no_backup() {
  export FAKE_DEFAULTS=fail
  run_job
  expect "backups" "$(backups)" 1
  expect_text "notification" "$(cat "$STATE/notifications")" "No Time Machine backup found."
}

test_failed_backup_is_logged_and_retried() {
  at "2026-11-16 02:00"
  last_backup_ago 7
  export FAKE_BACKUP_EXIT=3
  run_job
  expect_text "log" "$(job_log)" "backup failed (exit 3)"
  at "2026-11-16 03:00"
  run_job
  expect "backup attempts" "$(backups)" 2
}

# --- Waiting after a restart ------------------------------------------------

test_catchup_waits_after_restart() {
  last_backup_ago 30
  export FAKE_BOOT=$(( FAKE_NOW - 60 ))   # up for one minute
  run_job
  expect "wait" "$(grep '^sleep' "$STATE/calls")" "sleep 840"
  expect "backups" "$(backups)" 1
}

test_catchup_does_not_wait_when_up_for_long() {
  last_backup_ago 30
  run_job
  expect "waits" "$(count '^sleep' "$STATE/calls")" 0
  expect "backups" "$(backups)" 1
}

test_catchup_skipped_if_a_backup_starts_during_wait() {
  last_backup_ago 30
  export FAKE_BOOT=$(( FAKE_NOW - 60 )) FAKE_BACKUP_STARTS_DURING_WAIT=1
  run_job
  expect "backups" "$(backups)" 0
}

# --- Options ----------------------------------------------------------------

test_dry_run_changes_nothing() {
  at "2026-11-16 03:00"
  last_backup_ago 80
  run_job --dry-run
  expect_text "output" "$(cat "$T/out")" "would start a nightly backup"
  expect_text "output" "$(cat "$T/out")" "would notify: No backup for 80 hours."
  expect "recorded calls" "$(cat "$STATE/calls")" ""
  expect "notifications" "$(notifications)" 0
  [ ! -e "$HOME/Library/Logs/tm-nightly.log" ] || fail "the dry run wrote the log"
  [ ! -e "$HOME/Library/Logs/tm-nightly.warned" ] || fail "the dry run saved the notification time"
  [ ! -e "$HOME/.config/Brewfile" ] || fail "the dry run saved a Brewfile"
}

test_now_backs_up_even_when_recent() {
  last_backup_ago 0
  run_job --now
  expect "backups" "$(backups)" 1
  expect_text "log" "$(job_log)" "starting manual backup"
}

test_unknown_option_is_rejected() {
  last_backup_ago 30
  run_job --dryrun
  expect "exit code" "$?" 2
  expect_text "output" "$(cat "$T/out")" "unknown option: --dryrun"
  expect "backups" "$(backups)" 0
  [ ! -e "$HOME/Library/Logs/tm-nightly.log" ] || fail "the run wrote the log"
}

test_help_prints_usage() {
  run_job --help
  expect "exit code" "$?" 0
  expect "first line" "$(head -1 "$T/out")" "Usage: tm-nightly.sh [--dry-run | --now]"
  expect "backups" "$(backups)" 0
}

# --- Homebrew ---------------------------------------------------------------

test_brewfile_saved_before_backup() {
  last_backup_ago 30
  run_job
  [ -s "$HOME/.config/Brewfile" ] || fail "no Brewfile saved"
  expect "first call" "$(head -1 "$STATE/calls" | cut -d' ' -f1-3)" "brew bundle dump"
  expect "backups" "$(backups)" 1
  expect "notifications" "$(notifications)" 0
}

test_brewfile_failure_notifies_and_backs_up() {
  last_backup_ago 30
  export FAKE_BREW=fail
  run_job
  expect "backups" "$(backups)" 1
  expect "notifications" "$(notifications)" 1
  expect_text "notification" "$(cat "$STATE/notifications")" "Couldn't save the Homebrew package list."
  expect_text "log" "$(job_log)" "fake brew failure"
}

test_works_without_homebrew() {
  no_brew
  last_backup_ago 30
  run_job
  expect "backups" "$(backups)" 1
  expect "notifications" "$(notifications)" 0
  [ ! -e "$HOME/.config/Brewfile" ] || fail "a Brewfile was saved without Homebrew"
  expect_no_text "log" "$(job_log)" "Homebrew"
}

test_brewfile_can_be_turned_off() {
  setting BREWFILE '""'
  last_backup_ago 30
  run_job
  expect "brew calls" "$(count '^brew' "$STATE/calls")" 0
  expect "backups" "$(backups)" 1
}
