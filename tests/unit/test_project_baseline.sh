#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

assert_file_exists "$PROJECT_ROOT/ARCHITECTURE.md" "architecture decisions are documented"
assert_file_exists "$PROJECT_ROOT/MODULE_SPEC.md" "module contract is documented"
assert_file_exists "$PROJECT_ROOT/COMPATIBILITY.md" "compatibility policy is documented"
assert_file_exists "$PROJECT_ROOT/legacy/v1.0.1/vps_secure.sh" "legacy script is preserved"

actual_checksum=$(shasum -a 256 "$PROJECT_ROOT/legacy/v1.0.1/vps_secure.sh" | awk '{print $1}')
if [[ "$actual_checksum" == 'b48125bb46036baa82dce22725e62ff67a3377e1bad6efe28a87b3718049d4a0' ]]; then
    pass "legacy script remains immutable"
else
    fail "legacy script was modified"
fi

finish_tests
