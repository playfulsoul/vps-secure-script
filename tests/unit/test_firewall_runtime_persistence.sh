#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
FIREWALL_MODULE="$PROJECT_ROOT/modules/builtin/security-firewall/module.sh"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_root=$(mktemp -d)
bin_dir="$test_root/bin"
state_dir="$test_root/fake-state"
runtime_state="$test_root/module-state"
mkdir -p "$bin_dir" "$state_dir" "$runtime_state"
printf 'IPV6=no\n' > "$test_root/ufw-default"

cat > "$bin_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
action=${1:-}
shift || true
[[ ${1:-} == --quiet ]] && shift
unit=${1:-}
case "$action" in
    show)
        if [[ -e "$VPS_TEST_FIREWALL_STATE/unit-files/$unit" ]]; then
            printf '%s\n' "$VPS_TEST_FIREWALL_STATE/unit-files/$unit"
        else
            exit 1
        fi
        ;;
    is-enabled)
        case "$unit" in iptables.service|ip6tables.service) exit 0 ;; esac
        [[ -e "$VPS_TEST_FIREWALL_STATE/enabled-$unit" ]]
        ;;
    enable)
        : > "$VPS_TEST_FIREWALL_STATE/enabled-$unit"
        printf 'enable %s\n' "$unit" >> "$VPS_TEST_FIREWALL_STATE/systemctl.log"
        ;;
    disable)
        [[ ! -e "$VPS_TEST_FIREWALL_STATE/fail-disable" ]] || exit 1
        rm -f "$VPS_TEST_FIREWALL_STATE/enabled-$unit"
        printf 'disable %s\n' "$unit" >> "$VPS_TEST_FIREWALL_STATE/systemctl.log"
        ;;
    *) exit 64 ;;
esac
EOF

cat > "$bin_dir/ufw" <<'EOF'
#!/usr/bin/env bash
set -u
case "$*" in
    status|'status verbose')
        if [[ -e "$VPS_TEST_FIREWALL_STATE/inactive" ]]; then
            printf 'Status: inactive\n'
            exit 0
        fi
        printf '%s\n' \
            'Status: active' \
            '22/tcp ALLOW IN Anywhere' \
            '45678/tcp ALLOW IN Anywhere'
        ;;
    'show added')
        printf '%s\n' 'ufw allow 22/tcp' 'ufw allow 45678/tcp'
        ;;
    reload)
        : > "$VPS_TEST_FIREWALL_STATE/runtime-fresh"
        printf 'reload\n' >> "$VPS_TEST_FIREWALL_STATE/ufw.log"
        ;;
    *) exit 64 ;;
esac
EOF

cat > "$bin_dir/iptables" <<'EOF'
#!/usr/bin/env bash
set -u
[[ ${1:-} == -S ]] || exit 64
case ${2:-} in
    INPUT) printf '%s\n' '-A INPUT -j ufw-before-input' ;;
    ufw-before-input) printf '%s\n' '-A ufw-before-input -j ufw-user-input' ;;
    ufw-user-input)
        printf '%s\n' '-A ufw-user-input -p tcp --dport 22 -j ACCEPT'
        [[ -e "$VPS_TEST_FIREWALL_STATE/runtime-fresh" ]] && \
            printf '%s\n' '-A ufw-user-input -p tcp --dport 45678 -j ACCEPT'
        ;;
    *) exit 1 ;;
esac
EOF

cat > "$bin_dir/iptables-save" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' 'COMMIT'
EOF
cat > "$bin_dir/ip6tables-save" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' 'COMMIT'
EOF
chmod +x "$bin_dir"/*

run_firewall() {
    PATH="$bin_dir:$PATH" \
    VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
    VPS_MODULE_ID=security.firewall \
    VPS_STATE_DIR="$runtime_state" \
    VPS_UFW_DEFAULT_FILE="$test_root/ufw-default" \
    VPS_TEST_FIREWALL_STATE="$state_dir" \
    VPS_FIREWALL_PERSISTENCE_UNITS='netfilter-persistent.service nftables.service iptables.service ip6tables.service' \
        bash -c '
            source "$1" backup >/dev/null
            vps_require_root() { return 0; }
            firewall_supported_platform() { return 0; }
            firewall_ports() { printf "22\n"; }
            shift
            "$@"
        ' _ "$FIREWALL_MODULE" "$@"
}

# Real systemd aliases can return success from is-enabled while disabled.
mkdir -p "$state_dir/unit-files"
: > "$state_dir/unit-files/netfilter-persistent.service"
ln -s netfilter-persistent.service "$state_dir/unit-files/iptables.service"
ln -s netfilter-persistent.service "$state_dir/unit-files/ip6tables.service"
assert_eq '' "$(run_firewall firewall_persistence_conflicts)" \
    'disabled canonical owner is not reported through enabled aliases'
: > "$state_dir/enabled-netfilter-persistent.service"
assert_eq 'netfilter-persistent.service' "$(run_firewall firewall_persistence_conflicts)" \
    'aliases resolve by fragment path and report one canonical owner'

# Matrix A: an old persistent snapshot owns boot while UFW is not enabled.
: > "$state_dir/enabled-netfilter-persistent.service"
actual=$(run_firewall firewall_preflight 2>&1)
result=$?
assert_eq '30' "$result" "preflight rejects stale runtime rules with UFW boot disabled"
assert_contains "$actual" 'ufw.service 未启用' "preflight reports the missing UFW boot owner"
assert_contains "$actual" 'netfilter-persistent.service' "preflight reports the competing persistence owner"
assert_contains "$actual" '45678/tcp' "preflight compares configured allows with the running kernel chain"

actual=$(run_firewall firewall_persistence_configure 2>&1)
result=$?
assert_eq '0' "$result" "explicit persistence repair succeeds for the disabled-UFW matrix"
assert_contains "$actual" '唯一已启用' "repair explains the resulting single boot owner"
if [[ -e "$state_dir/enabled-ufw.service" ]]; then
    pass "repair enables UFW at boot"
else
    fail "repair enables UFW at boot"
fi
if [[ ! -e "$state_dir/enabled-netfilter-persistent.service" ]]; then
    pass "repair disables the stale netfilter boot loader"
else
    fail "repair disables the stale netfilter boot loader"
fi

transaction=$(VPS_PLATFORM_ROOT="$PROJECT_ROOT" VPS_STATE_DIR="$runtime_state" \
    bash -c 'source "$1"; vps_last_transaction security.firewall' _ \
    "$PROJECT_ROOT/core/runtime.sh")
assert_file_exists "$transaction/iptables.before" "repair backs up the running IPv4 rules before switching owners"

# Simulated reboot: only the enabled UFW owner loads the current rules.
rm -f "$state_dir/runtime-fresh"
[[ -e "$state_dir/enabled-ufw.service" ]] && : > "$state_dir/runtime-fresh"
if run_firewall firewall_verify >/dev/null 2>&1; then
    pass "reboot simulation restores the current UFW rules after repair"
else
    fail "reboot simulation restores the current UFW rules after repair"
fi

run_firewall firewall_rollback_dir "$transaction" >/dev/null
if [[ ! -e "$state_dir/enabled-ufw.service" ]]; then
    pass "persistence rollback restores the original disabled UFW state"
else
    fail "persistence rollback restores the original disabled UFW state"
fi
if [[ -e "$state_dir/enabled-netfilter-persistent.service" ]]; then
    pass "persistence rollback restores the original competing service state"
else
    fail "persistence rollback restores the original competing service state"
fi

# Matrix B: both services are enabled. It must fail even when UFW happened to run last.
: > "$state_dir/enabled-ufw.service"
: > "$state_dir/enabled-netfilter-persistent.service"
: > "$state_dir/runtime-fresh"
actual=$(run_firewall firewall_verify 2>&1)
result=$?
assert_eq '50' "$result" "verification rejects boot-order-dependent success"
assert_contains "$actual" '冲突的开机持久化服务' "verification identifies the hidden boot-order conflict"

# Reverse the simulated boot order: the stale snapshot now wins and the app rule disappears.
rm -f "$state_dir/runtime-fresh"
actual=$(run_firewall firewall_preflight 2>&1)
result=$?
assert_eq '30' "$result" "preflight rejects the reverse boot order with stale runtime rules"
assert_contains "$actual" '45678/tcp' "reverse boot-order failure identifies the missing runtime rule"

: > "$state_dir/systemctl.log"
actual=$(run_firewall firewall_apply 2>&1)
result=$?
assert_eq '30' "$result" "ordinary apply refuses to silently switch persistence owners"
if grep -q '^disable ' "$state_dir/systemctl.log"; then
    fail "ordinary apply must not disable another persistence owner"
else
    pass "ordinary apply leaves competing services unchanged"
fi

actual=$(run_firewall firewall_persistence_configure 2>&1)
result=$?
assert_eq '0' "$result" "explicit repair resolves the dual-enabled matrix"
rm -f "$state_dir/runtime-fresh"
[[ -e "$state_dir/enabled-ufw.service" ]] && : > "$state_dir/runtime-fresh"
if run_firewall firewall_verify >/dev/null 2>&1; then
    pass "dual-enabled repair remains valid after the reboot simulation"
else
    fail "dual-enabled repair remains valid after the reboot simulation"
fi

# Matrix C: UFW is truly inactive, not just disabled at boot.
: > "$state_dir/inactive"
: > "$state_dir/enabled-netfilter-persistent.service"
: > "$state_dir/ufw.log"
: > "$state_dir/systemctl.log"
actual=$(run_firewall firewall_preflight 2>&1)
assert_eq 30 "$?" 'inactive preflight reports failure'
assert_contains "$actual" 'netfilter-persistent.service' 'inactive preflight still reports the owner conflict'
actual=$(run_firewall firewall_plan repair-persistence)
assert_contains "$actual" '不会启用 UFW' 'repair plan distinguishes preparation from activation'
actual=$(run_firewall firewall_persistence_configure 2>&1)
assert_eq 0 "$?" 'inactive repair resolves conflict without requiring apply first'
assert_contains "$actual" 'UFW 仍未启用' 'inactive repair never claims the firewall is active'
assert_eq '' "$(cat "$state_dir/ufw.log")" 'inactive repair does not reload, enable, or change UFW rules'
assert_eq 'disable netfilter-persistent.service' "$(cat "$state_dir/systemctl.log")" \
    'inactive repair disables only canonical boot loader, without stop or UFW enable'
transaction=$(VPS_PLATFORM_ROOT="$PROJECT_ROOT" VPS_STATE_DIR="$runtime_state" \
    bash -c 'source "$1"; vps_last_transaction security.firewall' _ "$PROJECT_ROOT/core/runtime.sh")
assert_eq no "$(cat "$transaction/original_active")" 'inactive state is recorded for accurate completion reporting'
actual=$(run_firewall firewall_persistence_configure 2>&1)
assert_eq 0 "$?" 'inactive repeat repair is a no-op'
assert_contains "$actual" '未发现开机持久化冲突' 'no-op directs user to review rules before activation'
run_firewall firewall_rollback_dir "$transaction" >/dev/null
assert_eq 'netfilter-persistent.service' "$(run_firewall firewall_persistence_conflicts)" \
    'inactive preparation rollback restores canonical boot loader'
: > "$state_dir/fail-disable"
actual=$(run_firewall firewall_persistence_configure 2>&1)
assert_eq 40 "$?" 'failed inactive preparation reports failure and compensates'
assert_contains "$actual" '已恢复模块负责的配置' 'failed disable retains rollback semantics'
assert_eq '' "$(cat "$state_dir/ufw.log")" 'failed preparation never enables or reloads UFW'

rm -rf "$test_root"
finish_tests
