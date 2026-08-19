#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
SCRIPT="$PROJECT_ROOT/vps_secure.sh"
FAIL2BAN_MODULE="$PROJECT_ROOT/modules/builtin/security-fail2ban/module.sh"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

# The pattern is intentionally literal; it detects the removed fallback expression.
# shellcheck disable=SC2016
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

if grep -q 'service_active' "$FAIL2BAN_MODULE" && \
   grep -q 'service_enabled' "$FAIL2BAN_MODULE" && \
   grep -q 'systemctl stop fail2ban' "$FAIL2BAN_MODULE"; then
    pass "Fail2Ban rollback records and restores the previous service state"
else
    fail "Fail2Ban rollback must restore the previous service state"
fi

candidate_file=$(mktemp)
VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
VPS_MODULE_ID=security.fail2ban \
    bash -c '
        source "$1" backup >/dev/null
        fail2ban_write_candidate "$2" "32876" systemd
    ' _ "$FAIL2BAN_MODULE" "$candidate_file"
if grep -Eq '^logpath =[[:space:]]*$' "$candidate_file" && \
   grep -q '^backend = systemd$' "$candidate_file"; then
    pass "Fail2Ban systemd configuration clears inherited log paths"
else
    fail "Fail2Ban systemd configuration must clear inherited log paths"
fi
rm -f "$candidate_file"

readiness_root=$(mktemp -d)
readiness_counter="$readiness_root/ping-count"
printf '0\n' > "$readiness_counter"
cat > "$readiness_root/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
set -u
case ${1:-} in
    ping)
        count=$(<"$VPS_TEST_READINESS_COUNTER")
        count=$((count + 1))
        printf '%s\n' "$count" > "$VPS_TEST_READINESS_COUNTER"
        (( count >= 3 ))
        ;;
    status)
        exit 0
        ;;
    *)
        exit 64
        ;;
esac
EOF
chmod +x "$readiness_root/fail2ban-client"
actual=$(PATH="$readiness_root:$PATH" \
    VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
    VPS_MODULE_ID=security.fail2ban \
    VPS_TEST_READINESS_COUNTER="$readiness_counter" \
    VPS_FAIL2BAN_READY_ATTEMPTS=3 \
    VPS_FAIL2BAN_READY_DELAY=0 \
    bash -c '
        source "$1" backup >/dev/null
        fail2ban_verify
    ' _ "$FAIL2BAN_MODULE")
assert_contains "$actual" '已通过验证' "Fail2Ban verification waits for a delayed service socket"
actual=$(<"$readiness_counter")
assert_eq '3' "$actual" "Fail2Ban readiness check uses bounded retries"
rm -rf "$readiness_root"

if grep -q 'systemctl enable --now fail2ban' "$FAIL2BAN_MODULE"; then
    fail "Fail2Ban apply must not start and immediately restart the service"
else
    pass "Fail2Ban apply avoids redundant service startup"
fi

finish_tests
