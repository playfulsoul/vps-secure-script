#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
failures=0

if ! "$TEST_DIR/static.sh"; then
    failures=$((failures + 1))
fi

while IFS= read -r test_file; do
    printf '\n%s\n' "==> ${test_file#"$TEST_DIR/"}"
    if ! "$test_file"; then
        failures=$((failures + 1))
    fi
done < <(find "$TEST_DIR/unit" -type f -name 'test_*.sh' | sort)

if command -v python3 >/dev/null 2>&1; then
    printf '\n%s\n' '==> Python manual enrollment tests'
    if ! (cd "$TEST_DIR/.." && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_manual_join_client); then
        failures=$((failures + 1))
    fi
else
    printf '\n%s\n' 'not ok - Python 3 is required for manual enrollment tests' >&2
    failures=$((failures + 1))
fi

if (( failures > 0 )); then
    printf '\n%s test suite(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nAll test suites passed.\n'
