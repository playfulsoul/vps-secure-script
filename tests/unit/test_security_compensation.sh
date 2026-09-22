#!/usr/bin/env bash

# Functions below replace commands called indirectly by sourced modules.
# ShellCheck 0.9 reports SC2317 and 0.11 reports SC2329 for these doubles.
# Each subshell intentionally sets its own environment; it is not propagated.
# shellcheck disable=SC2317,SC2329,SC2030,SC2031
set -u
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=${VPS_TEST_SOURCE_ROOT:-$(cd -- "$TEST_DIR/../.." && pwd)}
# shellcheck source=../test_helper.sh
source "$TEST_DIR/../test_helper.sh"
test_root=$(mktemp -d)
test_root=$(cd "$test_root" && pwd -P)
trap 'rm -rf -- "$test_root"' EXIT

run_case() (
    module=$1 fault=$2 action=${3:-apply}
    export VPS_PLATFORM_ROOT=$PROJECT_ROOT
    export VPS_STATE_DIR="$test_root/$module-$fault-$action/state"
    export VPS_FAIL2BAN_CONFIG_ROOT="$test_root/$module-$fault-$action/config"
    export VPS_FAIL2BAN_CONFIG="$VPS_FAIL2BAN_CONFIG_ROOT/jail.d/90-vps-secure.local"
    fixture="$test_root/$module-$fault-$action"
    mkdir -p "$VPS_FAIL2BAN_CONFIG_ROOT/jail.d"
    printf 'original\n' > "$VPS_FAIL2BAN_CONFIG"
    printf 'disabled\n' > "$fixture/boot"
    : > "$fixture/commands"
    # Source dispatcher in read-only backup mode; no real system commands run.
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/modules/builtin/security-$module/module.sh" backup >/dev/null
    vps_require_root() { return 0; }
    fail2ban_check() { return 0; }
    fail2ban_ports() { printf '32876\n'; }
    fail2ban_backend() { printf 'systemd\n'; }
    fail2ban_verify() { [[ "$fault" != verify ]]; }
    firewall_check() { return 0; }
    firewall_ports() { printf '32876\n'; }
    firewall_is_active() { return 0; }
    firewall_persistence_conflicts() { return 0; }
    firewall_runtime_config_rules_verify() { return 0; }
    firewall_backup_runtime() { return 0; }
    firewall_verify() { [[ "$fault" == success ]]; }
    firewall_ufw_service_enabled() { grep -q enabled "$fixture/boot"; }
    firewall_rule_exists() { [[ -f "$fixture/rule" ]]; }
    ufw() {
        printf 'ufw %s\n' "$*" >> "$fixture/commands"
        case "$*" in
            'allow 32876/tcp')
                touch "$fixture/rule"
                [[ "$fault" != term ]] || sh -c 'kill -TERM "$PPID"'
                [[ "$fault" != apply && "$fault" != recovery ]] ;;
            '--force delete allow 32876/tcp')
                [[ "$fault" != recovery ]] || return 1
                rm -f "$fixture/rule" ;;
            reload) [[ "$fault" == success ]] ;;
            *) return 0 ;;
        esac
    }
    fail2ban-client() {
        printf 'client %s\n' "$*" >> "$fixture/commands"
        [[ "$fault" != term ]] || sh -c 'kill -TERM "$PPID"'
        [[ "$fault" != apply && "$fault" != recovery ]]
    }
    systemctl() {
        printf 'systemctl %s\n' "$*" >> "$fixture/commands"
        case "$1" in
            is-active|is-enabled) return 1 ;;
            enable) printf 'enabled\n' > "$fixture/boot" ;;
            disable|stop)
                [[ "$fault" != recovery ]] || return 1
                printf 'disabled\n' > "$fixture/boot" ;;
            restart) [[ "$fault" != service ]] ;;
        esac
    }
    if [[ "$fault" == pointer ]]; then
        vps_set_last_transaction() { return 1; }
        firewall_verify() { return 0; }
    fi
    if [[ "$fault" == prepare ]]; then
        firewall_tx_prepare() { return 40; }
        fail2ban_tx_prepare() { return 40; }
    fi
    if [[ "$fault" == marker ]]; then
        firewall_tx_phase() { [[ "$2" != committed ]] && printf '%s\n' "$2" > "$1/phase"; }
        fail2ban_tx_phase() { [[ "$2" != committed ]] && printf '%s\n' "$2" > "$1/phase"; }
        firewall_verify() { return 0; }
    fi
    "${module}_${action}"
)

for module in fail2ban firewall; do
    for fault in apply verify recovery pointer prepare marker term; do
        run_case "$module" "$fault" > "$test_root/result" 2>&1
        rc=$?
        actual=$(cat "$test_root/result")
        expected=40
        [[ "$fault" != verify ]] || expected=50
        [[ "$fault" != recovery ]] || expected=60
        assert_eq "$expected" "$rc" "$module $fault reports the correct failure"
        fixture="$test_root/$module-$fault-apply"
        if [[ "$fault" == recovery ]]; then
            assert_contains "$actual" '自动恢复未完成' "$module reports compensation failure explicitly"
            assert_file_exists "$fixture/state/modules/security-$module/pending_transaction" "$module preserves incomplete recovery pointer"
            continue
        fi
        if [[ "$module" == fail2ban ]]; then
            assert_eq original "$(cat "$fixture/config/jail.d/90-vps-secure.local")" "$module $fault preserves original config"
        elif [[ -e "$fixture/rule" ]]; then
            fail "$module $fault left added rule"
        else
            pass "$module $fault leaves no added rule"
        fi
        if [[ "$fault" == prepare ]]; then
            assert_eq '' "$(sed '/systemctl is-/d' "$fixture/commands")" "$module metadata failure stops before mutation"
        else
            assert_contains "$actual" '原操作未完成' "$module $fault never claims original success"
        fi
    done
done

actual=$(run_case firewall recovery persistence_configure 2>&1)
assert_eq 60 "$?" 'persistence repair surfaces compensation failure'
assert_contains "$actual" '自动恢复未完成' 'persistence repair retains recovery guidance'

# Exercise retry semantics with real wrapper and restore code, isolated fixtures.
for module in fail2ban firewall; do
    run_case "$module" success >/dev/null 2>&1
    assert_eq 0 "$?" "$module successful apply commits"
    fixture="$test_root/$module-success-apply"
    actual=$(
        export VPS_PLATFORM_ROOT=$PROJECT_ROOT VPS_STATE_DIR="$fixture/state"
        export VPS_FAIL2BAN_CONFIG="$fixture/config/jail.d/90-vps-secure.local"
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/modules/builtin/security-$module/module.sh" backup >/dev/null
        vps_require_root() { return 0; }
        systemctl() { return 0; }
        ufw() { rm -f "$fixture/rule"; }
        firewall_rule_exists() { [[ -f "$fixture/rule" ]]; }
        "${module}_rollback" || exit $?
        printf 'later\n' > "$VPS_FAIL2BAN_CONFIG"
        touch "$fixture/rule"
        "${module}_rollback" || exit $?
        [[ "$(cat "$VPS_FAIL2BAN_CONFIG")" == later && -f "$fixture/rule" ]]
    )
    assert_eq 0 "$?" "$module repeated rollback preserves later changes"
    assert_contains "$actual" '无需重复修改' "$module repeated rollback is explicit"
done

for module in fail2ban firewall; do
    fixture="$test_root/$module-recovery-apply"
    actual=$(
        exec 2>&1
        export VPS_PLATFORM_ROOT=$PROJECT_ROOT VPS_STATE_DIR="$fixture/state"
        export VPS_FAIL2BAN_CONFIG="$fixture/config/jail.d/90-vps-secure.local"
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/modules/builtin/security-$module/module.sh" backup >/dev/null
        vps_require_root() { return 0; }
        systemctl() { return 0; }
        ufw() { rm -f "$fixture/rule"; }
        firewall_rule_exists() { [[ -f "$fixture/rule" ]]; }
        # Any entry into the implementation would be a test failure.
        fail2ban_apply_impl() { return 99; }
        firewall_apply_impl() { return 99; }
        "${module}_apply"
        printf 'blocked=%s\n' "$?"
        "${module}_rollback" || exit $?
        test ! -e "$fixture/state/modules/security-$module/pending_transaction"
    )
    assert_eq 0 "$?" "$module explicit recovery retry clears pending evidence only on success"
    assert_contains "$actual" 'blocked=40' "$module blocks apply while compensation remains incomplete"
    assert_contains "$actual" '未完成恢复记录' "$module explains recovery required before a new apply"
done

for module in fail2ban firewall; do
    fixture="$test_root/$module-success-apply"
    lock="$fixture/state/modules/security-$module/operation-lock"
    mkdir "$lock"
    actual=$(
        export VPS_PLATFORM_ROOT=$PROJECT_ROOT VPS_STATE_DIR="$fixture/state"
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/modules/builtin/security-$module/module.sh" backup >/dev/null
        vps_require_root() { return 0; }
        "${module}_apply"
    )
    assert_eq 40 "$?" "$module refuses concurrent or stale-locked operations"
    if [[ -d "$lock" ]]; then pass "$module preserves another operation's lock"; else fail 'lock removed'; fi
done
finish_tests
