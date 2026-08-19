#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
SCRIPT="$PROJECT_ROOT/vps_secure.sh"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

if grep -q 'CUR_SSH_PORT=${CUR_SSH_PORT:-22}' "$SCRIPT"; then
    fail "security workflows must not fall back to SSH port 22"
else
    pass "security workflows do not fall back to SSH port 22"
fi

if grep -q 'cat > /etc/fail2ban/jail.local' "$SCRIPT"; then
    fail "Fail2Ban installation must not overwrite jail.local"
else
    pass "Fail2Ban installation does not overwrite jail.local"
fi

if grep -q 'config_file=/etc/fail2ban/jail.d/90-vps-secure.local' "$SCRIPT"; then
    pass "Fail2Ban uses a platform-owned configuration drop-in"
else
    fail "Fail2Ban platform-owned configuration drop-in is missing"
fi

if grep -A80 '^install_firewall()' "$SCRIPT" | grep -Eq 'ufw allow (80|443)|add-port=(80|443)'; then
    fail "initial firewall setup must not open web ports by default"
else
    pass "initial firewall setup does not open web ports by default"
fi

finish_tests
