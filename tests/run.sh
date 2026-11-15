#!/bin/bash
# run.sh: run the tests. They use fake system commands (see lib.sh), so they
# never start a backup, change Time Machine settings or show notifications.
#
# Usage: tests/run.sh [NAME]   run all tests, or those whose name contains NAME

set -u
cd "$(dirname "$0")"

TEST_ROOT=$(mktemp -d -t tm-tests)
trap 'rm -rf "$TEST_ROOT"' EXIT

. ./lib.sh
for file in test_*.sh; do
  . "./$file"
done

passed=0
failed=0
for t in $(declare -F | awk '{print $3}' | grep '^test_' | grep -F -- "${1:-}"); do
  if out=$( (setup "$t" && "$t") 2>&1 ); then
    passed=$((passed + 1))
    echo "ok    $t"
  else
    failed=$((failed + 1))
    echo "FAIL  $t"
    [ -n "$out" ] && echo "$out"
  fi
done

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
