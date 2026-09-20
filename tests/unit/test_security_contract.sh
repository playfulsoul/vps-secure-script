#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
SSH_CORE="$PROJECT_ROOT/core/ssh.sh"
FIREWALL_MODULE="$PROJECT_ROOT/modules/builtin/security-firewall/module.sh"
FAIL2BAN_MODULE="$PROJECT_ROOT/modules/builtin/security-fail2ban/module.sh"
REMOTE_DESKTOP_MODULE="$PROJECT_ROOT/modules/builtin/applications-remote-desktop/module.sh"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

# The pattern is intentionally literal; it detects the removed fallback expression.
# shellcheck disable=SC2016
if grep -q 'CUR_SSH_PORT=${CUR_SSH_PORT:-22}' \
    "$SSH_CORE" "$FIREWALL_MODULE" "$FAIL2BAN_MODULE"; then
    fail "security workflows must not fall back to SSH port 22"
else
    pass "security workflows do not fall back to SSH port 22"
fi

if grep -q 'cat > /etc/fail2ban/jail.local' "$FAIL2BAN_MODULE"; then
    fail "Fail2Ban installation must not overwrite jail.local"
else
    pass "Fail2Ban installation does not overwrite jail.local"
fi

# shellcheck disable=SC2016
if grep -q 'CONFIG_RELATIVE=${VPS_FAIL2BAN_CONFIG_RELATIVE:-jail.d/90-vps-secure.local}' \
    "$FAIL2BAN_MODULE"; then
    pass "Fail2Ban uses a platform-owned configuration drop-in"
else
    fail "Fail2Ban platform-owned configuration drop-in is missing"
fi

if grep -Eq 'ufw allow (80|443)|add-port=(80|443)' "$FIREWALL_MODULE"; then
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
cat > "$readiness_root/iptables" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "$*" == '-S INPUT' ]] || exit 64
printf '%s\n' \
    '-A INPUT -j f2b-sshd' \
    '-A INPUT -j f2b-sshd'
EOF
chmod +x "$readiness_root/fail2ban-client" "$readiness_root/iptables"
actual=$(PATH="$readiness_root:$PATH" \
    VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
    VPS_MODULE_ID=security.fail2ban \
    VPS_TEST_READINESS_COUNTER="$readiness_counter" \
    VPS_FAIL2BAN_READY_ATTEMPTS=3 \
    VPS_FAIL2BAN_READY_DELAY=0 \
    bash -c '
        source "$1" backup >/dev/null
        fail2ban_verify
    ' _ "$FAIL2BAN_MODULE" 2>&1)
assert_contains "$actual" '已通过验证' "Fail2Ban verification waits for a delayed service socket"
assert_contains "$actual" '不能判断故障由 Fail2Ban 引起' \
    "Fail2Ban duplicate-hook warning avoids unsupported causal claims"
actual=$(<"$readiness_counter")
assert_eq '3' "$actual" "Fail2Ban readiness check uses bounded retries"
rm -rf "$readiness_root"

if grep -q 'systemctl enable --now fail2ban' "$FAIL2BAN_MODULE"; then
    fail "Fail2Ban apply must not start and immediately restart the service"
else
    pass "Fail2Ban apply avoids redundant service startup"
fi

if grep -Eq 'ufw allow[[:space:]]+3389|0\.0\.0\.0:3389|port=3389([[:space:]]|$)' \
    "$REMOTE_DESKTOP_MODULE"; then
    fail "remote desktop must not expose RDP publicly"
else
    pass "remote desktop does not expose RDP publicly"
fi

if grep -q 'AllowRootLogin false' "$REMOTE_DESKTOP_MODULE" && \
   grep -q 'AlwaysGroupCheck true' "$REMOTE_DESKTOP_MODULE" && \
   grep -q "TerminalServerUsers \"\$RD_GROUP\"" "$REMOTE_DESKTOP_MODULE"; then
    pass "remote desktop enforces non-root group-gated login"
else
    fail "remote desktop must enforce non-root group-gated login"
fi

if grep -q 'apt-get purge -y --no-auto-remove' "$REMOTE_DESKTOP_MODULE" && \
   ! grep -Eq 'apt-get.*autoremove' "$REMOTE_DESKTOP_MODULE"; then
    pass "remote desktop rollback avoids broad package autoremove"
else
    fail "remote desktop rollback must avoid broad package autoremove"
fi

quiesce_line=$(grep -n 'rd_quiesce_xrdp_units ||' "$REMOTE_DESKTOP_MODULE" | cut -d: -f1)
session_line=$(grep -n "rd_quiesce_xrdp_sessions \"\$user\" ||" "$REMOTE_DESKTOP_MODULE" | cut -d: -f1)
purge_line=$(grep -n 'apt-get purge -y --no-auto-remove' "$REMOTE_DESKTOP_MODULE" | cut -d: -f1)
if [[ -n "$quiesce_line" && -n "$session_line" && -n "$purge_line" ]] && \
   (( quiesce_line < session_line && session_line < purge_line )) && \
   grep -q 'systemctl kill --kill-whom=all --signal=TERM' "$REMOTE_DESKTOP_MODULE" && \
   grep -q 'systemctl kill --kill-whom=all --signal=KILL' "$REMOTE_DESKTOP_MODULE" && \
   grep -q "loginctl terminate-session \"\$session\"" "$REMOTE_DESKTOP_MODULE" && \
   ! grep -Eq 'loginctl terminate-user|pkill|killall' "$REMOTE_DESKTOP_MODULE" && \
   ! grep -q -- '--kill-who=all' "$REMOTE_DESKTOP_MODULE"; then
    pass "remote desktop drains unit cgroups and exact logind sessions before package purge"
else
    fail "remote desktop must empty managed unit cgroups and exact sessions before package purge"
fi

# shellcheck disable=SC2016
if grep -Fq 'rd_signal_xrdp_session_scope()' "$REMOTE_DESKTOP_MODULE" && \
   grep -Fq 'systemctl kill --kill-whom=all --signal="$signal" "$scope"' \
       "$REMOTE_DESKTOP_MODULE" && \
   grep -Fq '[[ "$uid" == "$expected_uid" ]] || return 1' \
       "$REMOTE_DESKTOP_MODULE" && \
   grep -Fq '[[ "$state" != closing && "$managed_sesman" != yes ]]' \
       "$REMOTE_DESKTOP_MODULE"; then
    pass "remote desktop constrains closing-session cleanup to the exact user-owned scope"
else
    fail "remote desktop must fail closed around half-closed session scope cleanup"
fi

# shellcheck disable=SC2016
if grep -q 'panel_services=$(rd_panel_service_states)' "$REMOTE_DESKTOP_MODULE" && \
   grep -q "'1panel\*\.service'" "$REMOTE_DESKTOP_MODULE"; then
    pass "remote desktop preserves the deployed 1Panel service layout"
else
    fail "remote desktop must track the real 1Panel service units"
fi

mask_line=$(grep -n 'rd_mask_units_for_install ||' "$REMOTE_DESKTOP_MODULE" | cut -d: -f1)
install_line=$(grep -n 'vps_apt_install --no-install-recommends' "$REMOTE_DESKTOP_MODULE" | cut -d: -f1)
unmask_line=$(grep -n 'rd_unmask_units_for_start ||' "$REMOTE_DESKTOP_MODULE" | cut -d: -f1)
start_line=$(grep -n 'systemctl start xrdp ||' "$REMOTE_DESKTOP_MODULE" | cut -d: -f1)
if [[ -n "$mask_line" && -n "$install_line" && -n "$unmask_line" && -n "$start_line" ]] && \
   (( mask_line < install_line && install_line < unmask_line && unmask_line < start_line )); then
    pass "remote desktop keeps xrdp masked until loopback configuration is ready"
else
    fail "remote desktop must prevent package installation from briefly exposing RDP"
fi

finish_tests
