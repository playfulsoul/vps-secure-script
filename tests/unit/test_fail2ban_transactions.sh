#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
FAIL2BAN_MODULE="$PROJECT_ROOT/modules/builtin/security-fail2ban/module.sh"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_root=$(mktemp -d)
command_log="$test_root/commands"
config_root="$test_root/etc/fail2ban"
config_file="$config_root/jail.d/90-vps-secure.local"
state_root="$test_root/state"
mkdir -p "$test_root/bin" "$(dirname -- "$config_file")"
: > "$command_log"

cat > "$test_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'systemctl %s\n' "$*" >> "$VPS_TEST_COMMAND_LOG"
case "$*" in
    'is-active --quiet fail2ban'|'is-enabled --quiet fail2ban') exit 0 ;;
esac
exit 0
EOF

cat > "$test_root/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'fail2ban-client %s\n' "$*" >> "$VPS_TEST_COMMAND_LOG"
exit 0
EOF
chmod +x "$test_root/bin/systemctl" "$test_root/bin/fail2ban-client"

cat > "$config_file" <<'EOF'
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = 22
backend = systemd
logpath =
EOF

actual=$(PATH="$test_root/bin:$PATH" \
    VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
    VPS_MODULE_ID=security.fail2ban \
    VPS_STATE_DIR="$state_root" \
    VPS_FAIL2BAN_CONFIG_ROOT="$config_root" \
    VPS_FAIL2BAN_CONFIG="$config_file" \
    VPS_TEST_COMMAND_LOG="$command_log" \
    bash -c '
        source "$1" backup >/dev/null
        module_state=$(vps_module_state_dir security.fail2ban)
        baseline="$module_state/transactions/baseline"
        mkdir -p "$baseline"
        vps_set_last_transaction security.fail2ban "$baseline"
        vps_require_root() { return 0; }
        fail2ban_check() { return 0; }
        fail2ban_ports() { printf "22\n"; }
        fail2ban_backend() { printf "systemd\n"; }
        fail2ban_apply
        printf "last=%s\n" "$(vps_last_transaction security.fail2ban)"
        printf "baseline=%s\n" "$baseline"
    ' _ "$FAIL2BAN_MODULE" 2>&1)
result=$?

assert_eq '0' "$result" "repeated Fail2Ban apply succeeds as a no-op"
assert_contains "$actual" '未重启服务或创建新事务，保留现有回滚点' "repeated Fail2Ban apply explains rollback-point retention"
last=$(printf '%s\n' "$actual" | sed -n 's/^last=//p')
baseline=$(printf '%s\n' "$actual" | sed -n 's/^baseline=//p')
assert_eq "$baseline" "$last" "repeated Fail2Ban apply preserves the meaningful rollback point"
if grep -Eq '^systemctl (enable|restart) fail2ban$' "$command_log"; then
    fail "repeated Fail2Ban apply must not restart or re-enable a healthy service"
else
    pass "repeated Fail2Ban apply avoids redundant service changes"
fi

rm -rf "$test_root"
finish_tests
