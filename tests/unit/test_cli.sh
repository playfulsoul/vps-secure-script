#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
CLI="$PROJECT_ROOT/bin/vps"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

actual=$($CLI --version)
assert_eq 'vps-secure 2.0.0-dev' "$actual" "CLI reports the platform version"

actual=$($CLI module list)
assert_contains "$actual" 'system.doctor' "CLI lists the system doctor module"
assert_contains "$actual" 'security.ssh' "CLI lists the SSH module"
assert_contains "$actual" 'monitoring.network' "CLI lists the network monitoring module"

actual=$(printf '0\n' | "$CLI")
assert_contains "$actual" 'VPS Secure Platform' "interactive menu is generated from the module registry"

actual=$($CLI module info security.ssh)
assert_contains "$actual" 'high-risk' "CLI exposes module privilege level"

temporary_os_release=$(mktemp)
temporary_auth_log=$(mktemp)
printf '%s\n' 'ID=debian' 'VERSION_ID="12"' > "$temporary_os_release"
actual=$(VPS_OS_RELEASE_FILE="$temporary_os_release" \
    SSH_CONNECTION='198.51.100.7 50123 203.0.113.9 32876' \
    $CLI firewall plan)
assert_contains "$actual" 'SSH 端口: 32876' "firewall plan preserves the current custom SSH port"
assert_contains "$actual" '不默认开放 22、80 或 443' "firewall plan follows least-privilege defaults"

actual=$(VPS_OS_RELEASE_FILE="$temporary_os_release" \
    VPS_AUTH_LOG_FILE="$temporary_auth_log" \
    VPS_SYSTEMD_RUNTIME_DIR="$temporary_auth_log.missing-systemd" \
    SSH_CONNECTION='198.51.100.7 50123 203.0.113.9 32876' \
    $CLI fail2ban plan)
rm -f "$temporary_os_release" "$temporary_auth_log"
assert_contains "$actual" 'SSH 端口: 32876' "Fail2Ban plan uses the current custom SSH port"
assert_contains "$actual" '日志后端: logfile' "Fail2Ban plan selects an available Debian log backend"
assert_contains "$actual" '不覆盖 /etc/fail2ban/jail.local' "Fail2Ban plan preserves user configuration"

if $CLI module run security.ssh unsupported-action >/dev/null 2>&1; then
    fail "CLI rejects unsupported module actions"
else
    pass "CLI rejects unsupported module actions"
fi

if $CLI module run system.swap apply --size 1G >/dev/null 2>&1; then
    fail "CLI requires explicit confirmation for state changes"
else
    pass "CLI requires explicit confirmation for state changes"
fi

finish_tests
