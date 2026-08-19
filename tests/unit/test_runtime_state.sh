#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
VPS_STATE_DIR=$(mktemp -d)
export VPS_STATE_DIR
trap 'rm -rf "$VPS_STATE_DIR"' EXIT

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# shellcheck source=../../core/runtime.sh
source "$PROJECT_ROOT/core/runtime.sh"

transaction=$(vps_new_transaction_dir security.firewall)
if [[ -d "$transaction" ]]; then
    pass "runtime creates a private module transaction directory"
else
    fail "runtime creates a private module transaction directory"
fi

if vps_set_last_transaction security.firewall "$transaction"; then
    pass "runtime records the last successful transaction"
else
    fail "runtime records the last successful transaction"
fi

actual=$(vps_last_transaction security.firewall)
assert_eq "$transaction" "$actual" "runtime resolves a valid transaction inside module state"

printf '/tmp/outside-transaction\n' > "$(vps_module_state_dir security.firewall)/last_transaction"
if vps_last_transaction security.firewall >/dev/null 2>&1; then
    fail "runtime rejects transaction pointers outside module state"
else
    pass "runtime rejects transaction pointers outside module state"
fi

finish_tests
