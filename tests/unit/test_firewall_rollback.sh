#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
FIREWALL_MODULE="$PROJECT_ROOT/modules/builtin/security-firewall/module.sh"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_root=$(mktemp -d)
command_log="$test_root/ufw-commands"
mkdir -p "$test_root/bin"
cat > "$test_root/bin/ufw" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$VPS_TEST_UFW_LOG"
case "$*" in
    status)
        printf '%s\n' \
            'Status: active' \
            '32876/tcp ALLOW IN Anywhere'
        ;;
    'show added')
        printf 'ufw allow 32876/tcp\n'
        ;;
esac
EOF
chmod +x "$test_root/bin/ufw"

active_transaction="$test_root/active-transaction"
mkdir -p "$active_transaction"
printf 'yes\n' > "$active_transaction/original_active"
printf '32876\n' > "$active_transaction/added_ports"

: > "$command_log"
actual=$(PATH="$test_root/bin:$PATH" \
    VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
    VPS_MODULE_ID=security.firewall \
    VPS_TEST_UFW_LOG="$command_log" \
    SSH_CONNECTION='198.51.100.7 50123 203.0.113.9 32876' \
    bash -c '
        source "$1" backup >/dev/null
        firewall_rollback_dir "$2"
    ' _ "$FIREWALL_MODULE" "$active_transaction" 2>&1)
result=$?
assert_eq '10' "$result" "firewall rollback safely defers the active SSH session rule"
assert_contains "$actual" '保留当前 SSH 会话端口规则' "firewall rollback explains the retained rule"
if grep -q -- '--force delete allow 32876/tcp' "$command_log"; then
    fail "firewall rollback must not delete the active SSH session rule"
else
    pass "firewall rollback preserves the active SSH session rule"
fi

: > "$command_log"
PATH="$test_root/bin:$PATH" \
VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
VPS_MODULE_ID=security.firewall \
VPS_TEST_UFW_LOG="$command_log" \
SSH_CONNECTION='198.51.100.7 50123 203.0.113.9 22' \
    bash -c '
        source "$1" backup >/dev/null
        firewall_rollback_dir "$2"
    ' _ "$FIREWALL_MODULE" "$active_transaction" >/dev/null
if grep -q -- '--force delete allow 32876/tcp' "$command_log"; then
    pass "firewall rollback removes an added port after the session switches away"
else
    fail "firewall rollback removes an added port after the session switches away"
fi

inactive_transaction="$test_root/inactive-transaction"
mkdir -p "$inactive_transaction"
printf 'no\n' > "$inactive_transaction/original_active"
printf '32876\n' > "$inactive_transaction/added_ports"
: > "$command_log"
PATH="$test_root/bin:$PATH" \
VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
VPS_MODULE_ID=security.firewall \
VPS_TEST_UFW_LOG="$command_log" \
SSH_CONNECTION='198.51.100.7 50123 203.0.113.9 32876' \
    bash -c '
        source "$1" backup >/dev/null
        firewall_rollback_dir "$2"
    ' _ "$FIREWALL_MODULE" "$inactive_transaction" >/dev/null
actual=$(sed -n '1p' "$command_log")
assert_eq '--force disable' "$actual" "firewall rollback disables an originally inactive firewall before deleting rules"

rm -rf "$test_root"
finish_tests
