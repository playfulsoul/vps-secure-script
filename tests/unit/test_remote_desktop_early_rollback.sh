#!/usr/bin/env bash
set -u
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
source "$PROJECT_ROOT/tests/test_helper.sh"
VPS_PLATFORM_ROOT=$PROJECT_ROOT
VPS_MODULE_ID=applications.remote-desktop
export VPS_PLATFORM_ROOT VPS_MODULE_ID
source "$PROJECT_ROOT/modules/builtin/applications-remote-desktop/module.sh"
dpkg-query() { printf 'xrdp\tinstall ok installed\n'; return 1; }
rd_present_packages >/dev/null
assert_eq 40 "$?" "failed partial package inventory is not trusted as a baseline"
unset -f dpkg-query
temporary_root=$(mktemp -d)
trap 'rm -rf -- "$temporary_root"' EXIT
export VPS_STATE_DIR="$temporary_root/state"
export VPS_REMOTE_DESKTOP_TEST_MODE=yes
RD_CONFIG_DIR="$temporary_root/config"
RD_LIB_DIR="$temporary_root/lib"
RD_XRDP_DROPIN="$temporary_root/xrdp-dropin"
RD_SESMAN_DROPIN="$temporary_root/sesman-dropin"
RD_XRDP_UNIT_PATH="$temporary_root/xrdp.service"
RD_SESMAN_UNIT_PATH="$temporary_root/xrdp-sesman.service"
RD_PROC_ROOT="$temporary_root/proc"
mkdir -p "$RD_PROC_ROOT"
account=absent
query=ok
session_state=none
unit_failure=no
scenario=apt
original_mask=no
session_calls=0
rd_validate_managed_paths() { return 0; }
vps_require_root() { return 0; }
rd_is_managed() { return 1; }
rd_parse_options() { RD_USER='desktop-test'; }
rd_normalize_options() { return 0; }
rd_preflight() { return 0; }
rd_panel_service_states() { printf 'absent\n'; }
vps_require_ssh_ports() { printf '22\n'; }
rd_ufw_hash() { printf 'fixture\n'; }
rd_unique_packages() { printf 'xrdp\n'; }
rd_present_packages() { [[ ! -f "$temporary_root/installed" ]] || printf 'xrdp\n'; return 0; }
id() { [[ "$account" == present ]] || return 1; printf '1001\n'; }
getent() {
    [[ "$1" == passwd ]] || return 2
    [[ "$query" != failure ]] || return 1
    if [[ $# == 2 ]]; then
        [[ "$account" == present || "$query" == inconsistent ]] || return 2
        printf 'desktop-test:x:1001:1001::/nonexistent:/bin/sh\n'
    else
        [[ "$query" != enumeration-failure ]] || return 1
        printf 'root:x:0:0::/root:/bin/sh\n'
    fi
}
loginctl() {
    [[ "$session_state" != failure ]] || return 1
    [[ "$session_state" == none ]] || printf 'c1 1001 desktop-test\n'
}
rd_loginctl_value() {
    [[ "$session_state" != detail-failure ]] || return 1
    if [[ "$session_state" == graphical ]]; then printf 'xrdp-sesman\n'; else printf 'sshd\n'; fi
}
rd_quiesce_xrdp_sessions() { session_calls=$((session_calls + 1)); return 50; }
systemctl() {
    printf '%s\n' "$*" >> "$temporary_root/systemctl.log"
    case "$1" in
        mask)
            ln -sf /dev/null "$RD_XRDP_UNIT_PATH"
            [[ $# -gt 2 ]] || return 0
            if [[ "$scenario" == mask-partial && ! -e "$temporary_root/mask-failed" ]]; then
                : > "$temporary_root/mask-failed"
                return 1
            fi
            ln -sf /dev/null "$RD_SESMAN_UNIT_PATH" ;;
        is-enabled)
            if [[ "$2" == xrdp && "$original_mask" == yes ]]; then printf 'masked\n'; else printf 'disabled\n'; fi ;;
        is-active) printf 'inactive\n' ;;
        get-default) printf 'multi-user.target\n' ;;
    esac
    return 0
}
# Detailed cgroup draining is covered by test_remote_desktop.sh. Exercise the
# real unit-quiescing function here with absent cgroups, not a replacement.
rd_unit_cgroup_target() { printf 'absent\n'; }
rd_drain_unit_cgroup() { [[ "$unit_failure" == no ]]; }
rd_confirm_no_rdp_listener() { return 0; }
vps_apt_update() { [[ "$scenario" != apt ]]; }
vps_apt_install() { : > "$temporary_root/installed"; return 1; }
apt-get() { printf '%s\n' "$*" >> "$temporary_root/apt.log"; rm -f "$temporary_root/installed"; }
rd_verify_baseline() { return 0; }

for scenario in mask-partial apt packages; do
    for original_mask in no yes; do
        VPS_STATE_DIR="$temporary_root/state-$scenario-$original_mask"
        : > "$temporary_root/systemctl.log"
        : > "$temporary_root/apt.log"
        rm -f "$RD_XRDP_UNIT_PATH" "$RD_SESMAN_UNIT_PATH" "$temporary_root/installed" "$temporary_root/mask-failed"
        [[ "$original_mask" != yes ]] || ln -s /dev/null "$RD_XRDP_UNIT_PATH"
        output=$(rd_apply 2>&1)
        result=$?
        assert_eq 40 "$result" "$scenario preserves original failure after successful early rollback ($original_mask)"
        if [[ "$original_mask" == yes ]]; then
            assert_eq /dev/null "$(readlink "$RD_XRDP_UNIT_PATH")" "original mask is preserved"
        elif [[ -e "$RD_XRDP_UNIT_PATH" || -L "$RD_XRDP_UNIT_PATH" ]]; then
            fail "new xrdp mask must be removed"
        else pass "new xrdp mask removed"; fi
        if [[ -e "$RD_SESMAN_UNIT_PATH" || -L "$RD_SESMAN_UNIT_PATH" ]]; then
            fail "new sesman mask must be removed"
        else pass "new sesman mask removed"; fi
        if [[ "$output" == *'已保留安装期间创建的用户'* ]]; then
            fail "early rollback must not claim a nonexistent user was retained"
        else pass "early rollback does not claim user creation"; fi
        if grep -q '^start ' "$temporary_root/systemctl.log"; then
            fail "early rollback must not start originally inactive services"
        else pass "original inactive state is preserved"; fi
        if [[ "$scenario" == packages ]]; then
            assert_contains "$(<"$temporary_root/apt.log")" 'purge -y --no-auto-remove xrdp' "partial installation uses recorded package cleanup"
        elif [[ -s "$temporary_root/apt.log" ]]; then
            fail "pre-package failure must not purge packages"
        else pass "pre-package failure performs no package cleanup"; fi
    done
done

# Run the real restore path with a trusted early transaction but an NSS error.
VPS_STATE_DIR="$temporary_root/state-guard"
scenario=apt
original_mask=no
rm -f "$RD_XRDP_UNIT_PATH" "$RD_SESMAN_UNIT_PATH"
transaction=$(rd_create_transaction)
query=failure
: > "$temporary_root/apt.log"
rd_restore_transaction "$transaction" >/dev/null 2>&1
assert_eq 60 "$?" "restore stops on account query failure"
if [[ -e "$transaction/rolled_back" || -s "$temporary_root/apt.log" ]]; then
    fail "query failure must preserve evidence and avoid package cleanup"
else pass "query failure preserves evidence without purging"; fi
query=ok

transaction="$temporary_root/guard"
mkdir -p "$transaction"
printf 'user_existed=no\n' > "$transaction/metadata"
: > "$transaction/packages.present.before"
rd_set_install_phase "$transaction" prepared
scenario=apt
rd_quiesce_transaction_sessions "$transaction" desktop-test
assert_eq 0 "$?" "confirmed absent early user permits session-free rollback"
for query in failure enumeration-failure inconsistent; do
    rd_quiesce_transaction_sessions "$transaction" desktop-test
    assert_eq 50 "$?" "account query $query fails closed"
done
query=ok
for session_state in failure detail-failure graphical; do
    rd_quiesce_transaction_sessions "$transaction" desktop-test
    assert_eq 50 "$?" "session state $session_state fails closed"
done
session_state=none
for phase in user-setup unknown ''; do
    rd_set_install_phase "$transaction" "$phase"
    rd_quiesce_transaction_sessions "$transaction" desktop-test
    assert_eq 50 "$?" "phase $phase cannot bypass session cleanup"
done
rm -f "$transaction/install-phase"
rd_quiesce_transaction_sessions "$transaction" desktop-test
assert_eq 50 "$?" "legacy transaction stays strict"
rd_set_install_phase "$transaction" packages
printf 'xrdp\n' > "$transaction/packages.present.before"
rd_quiesce_transaction_sessions "$transaction" desktop-test
assert_eq 50 "$?" "prior xrdp installation stays strict"
: > "$transaction/packages.present.before"
printf 'user_existed=yes\n' > "$transaction/metadata"
rd_quiesce_transaction_sessions "$transaction" desktop-test
assert_eq 50 "$?" "missing original user stays strict"
account=present
rd_quiesce_transaction_sessions "$transaction" desktop-test
assert_eq 50 "$?" "existing user propagates strict session failure"
assert_eq 1 "$session_calls" "existing user invokes original session cleanup"
account=absent
printf 'user_existed=no\n' > "$transaction/metadata"
mkdir -p "$RD_PROC_ROOT/123"
printf 'xrdp\n' > "$RD_PROC_ROOT/123/comm"
rd_quiesce_transaction_sessions "$transaction" desktop-test >/dev/null 2>&1
assert_eq 50 "$?" "surviving xrdp process prevents early cleanup"
finish_tests
