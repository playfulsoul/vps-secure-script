#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
CLI="$PROJECT_ROOT/bin/vps"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

actual=$($CLI --version)
assert_eq 'vps-secure 2.0.0-beta.1' "$actual" "CLI reports the platform version"

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
assert_contains "$actual" '保持并放行 SSH 端口:' "firewall plan identifies the SSH allow-list"
assert_contains "$actual" '32876' "firewall plan preserves the current custom SSH port"
assert_contains "$actual" '不会自动新增网站端口 80/443' "firewall plan follows least-privilege defaults"
assert_contains "$actual" '现有用户防火墙规则保持不变' "firewall plan preserves existing rules"

actual=$(VPS_OS_RELEASE_FILE="$temporary_os_release" \
    VPS_AUTH_LOG_FILE="$temporary_auth_log" \
    VPS_SYSTEMD_RUNTIME_DIR="$temporary_auth_log.missing-systemd" \
    SSH_CONNECTION='198.51.100.7 50123 203.0.113.9 32876' \
    $CLI fail2ban plan)
assert_contains "$actual" 'SSH 端口:' "Fail2Ban plan identifies the protected SSH ports"
assert_contains "$actual" '32876' "Fail2Ban plan uses the current custom SSH port"
assert_contains "$actual" '日志后端: logfile' "Fail2Ban plan selects an available Debian log backend"
assert_contains "$actual" '不覆盖 /etc/fail2ban/jail.local' "Fail2Ban plan preserves user configuration"

preflight_root=$(mktemp -d)
mkdir -p "$preflight_root/config/jail.d" "$preflight_root/bin" "$preflight_root/systemd"
printf '%s\n' \
    '[sshd]' \
    'enabled = true' \
    'port = 22' \
    'logpath = %(sshd_log)s' \
    'backend = %(sshd_backend)s' > "$preflight_root/config/jail.local"
cat > "$preflight_root/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
set -u
config_root=''
while (( $# > 0 )); do
    case $1 in
        -c)
            config_root=$2
            shift 2
            ;;
        -t)
            shift
            ;;
        *)
            exit 64
            ;;
    esac
done
candidate="$config_root/jail.d/90-vps-secure.local"
[[ -f "$candidate" ]] || exit 1
grep -q '^backend = systemd$' "$candidate" || exit 1
grep -Eq '^logpath =[[:space:]]*$' "$candidate" || exit 1
grep -q '^logpath = %(sshd_log)s$' "$config_root/jail.local" || exit 1
EOF
cat > "$preflight_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$preflight_root/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x \
    "$preflight_root/bin/fail2ban-client" \
    "$preflight_root/bin/systemctl" \
    "$preflight_root/bin/journalctl"
actual=$(PATH="$preflight_root/bin:$PATH" \
    VPS_OS_RELEASE_FILE="$temporary_os_release" \
    VPS_SYSTEMD_RUNTIME_DIR="$preflight_root/systemd" \
    VPS_FAIL2BAN_CONFIG_ROOT="$preflight_root/config" \
    SSH_CONNECTION='198.51.100.7 50123 203.0.113.9 32876' \
    $CLI fail2ban preflight)
assert_contains "$actual" '临时合并配置预检通过' "Fail2Ban preflight validates a temporary merged configuration"
if [[ -e "$preflight_root/config/jail.d/90-vps-secure.local" ]]; then
    fail "Fail2Ban preflight must not write the live configuration tree"
else
    pass "Fail2Ban preflight leaves the live configuration tree unchanged"
fi
rm -rf "$preflight_root"
rm -f "$temporary_os_release" "$temporary_auth_log"

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
