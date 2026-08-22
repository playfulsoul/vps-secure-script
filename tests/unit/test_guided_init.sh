#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
CALL_LOG="$TEST_ROOT/calls.log"

VPS_PLATFORM_ROOT=$PROJECT_ROOT
VERSION=2.0.0-beta.5
export VPS_PLATFORM_ROOT VERSION CALL_LOG

# shellcheck source=../../core/ui.sh
source "$PROJECT_ROOT/core/ui.sh"

vps_ui_swap_recommendation() {
    printf '1G\n'
}

vps_module_run() {
    printf '%s\n' "$*" >> "$CALL_LOG"
    case "$1:$2" in
        system.bbr:verify) return 50 ;;
        *) return 0 ;;
    esac
}

# Decline the full package upgrade, accept recommended BBR and Swap defaults,
# then confirm the complete plan.
printf 'n\n\n\ny\n' | vps_ui_safe_init_flow >/dev/null

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

actual=$(<"$CALL_LOG")
assert_contains "$actual" 'security.firewall apply' "guided setup applies the firewall"
assert_contains "$actual" 'security.fail2ban apply' "guided setup applies Fail2Ban"
assert_contains "$actual" 'system.bbr apply' "guided setup enables supported BBR by default"
assert_contains "$actual" 'system.swap apply --size 1G' "guided setup applies the recommended Swap size"
if grep -q '^system.packages apply$' "$CALL_LOG"; then
    fail "guided setup respects the decision to skip package upgrades"
else
    pass "guided setup respects the decision to skip package upgrades"
fi
assert_contains "$actual" 'security.firewall verify' "guided setup verifies the firewall"
assert_contains "$actual" 'security.fail2ban verify' "guided setup verifies Fail2Ban"

finish_tests
