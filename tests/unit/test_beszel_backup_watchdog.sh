#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
watchdog="$PROJECT_ROOT/scripts/beszel-backup-watchdog.sh"
export PATH="$PROJECT_ROOT/tests/fixtures/backup-watchdog-bin:$PATH"
export VPS_BESZEL_BACKUP_RESULT="$test_root/onedrive-last-result"

printf 'result=success\nexit_code=0\ncompleted_utc=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$VPS_BESZEL_BACKUP_RESULT"
"$watchdog" check
assert_eq 0 "$?" 'watchdog accepts a fresh successful backup and active timer'

export VPS_TEST_BACKUP_SERVICE_RESULT=exit-code
actual=$("$watchdog" check 2>&1)
assert_eq 40 "$?" 'watchdog rejects a failed backup unit'
assert_contains "$actual" backup_service_failed 'failed unit reason is visible without logs'
unset VPS_TEST_BACKUP_SERVICE_RESULT

export VPS_TEST_TIMER_HEALTH=unhealthy
actual=$("$watchdog" check 2>&1)
assert_eq 40 "$?" 'watchdog rejects a disabled or inactive timer'
unset VPS_TEST_TIMER_HEALTH

touch -t 202001010000 "$VPS_BESZEL_BACKUP_RESULT"
actual=$("$watchdog" check 2>&1)
assert_eq 40 "$?" 'watchdog rejects a stale backup result'
touch "$VPS_BESZEL_BACKUP_RESULT"

printf 'result=failure\nexit_code=40\ncompleted_utc=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$VPS_BESZEL_BACKUP_RESULT"
actual=$("$watchdog" check 2>&1)
assert_eq 40 "$?" 'watchdog rejects a recorded backup failure'

"$watchdog" watch --unexpected >/dev/null 2>&1
assert_eq 64 "$?" 'watchdog refuses unsupported arguments'

finish_tests
