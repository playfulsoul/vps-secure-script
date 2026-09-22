#!/usr/bin/env bash

# This module owns one operation at a time. A pending record is recovery
# evidence, not a successful rollback point.
firewall_tx_new() {
    mkdir -p "$tx_state/transactions" || return 40
    mktemp -d "$tx_state/transactions/operation.XXXXXX"
}

firewall_tx_phase() {
    printf '%s\n' "$2" > "$1/phase.next" && mv -f "$1/phase.next" "$1/phase"
}

firewall_tx_prepare() {
    firewall_tx_phase "$1" prepared || return 40
    printf '%s\n' "$1" > "$tx_state/pending_transaction" || return 40
    tx_transaction=$1
    tx_armed=yes
}

firewall_tx_finish() {
    local rc=$1 recovery=0
    trap - EXIT HUP INT TERM
    if [[ "$tx_armed" == yes ]]; then
        printf '操作失败（退出码 %s），尝试恢复。事务: %s\n' "$rc" "$tx_transaction" >&2
        firewall_rollback_dir "$tx_transaction" || recovery=$?
        if (( recovery == 0 )) && firewall_tx_phase "$tx_transaction" compensated; then
            rm -f "$tx_state/pending_transaction" || rc=60
            printf '原操作未完成，已恢复模块负责的配置；事务证据已保留。\n' >&2
        else
            firewall_tx_phase "$tx_transaction" recovery_failed || true
            printf '自动恢复未完成（恢复退出码 %s）。请保留 SSH 会话并人工核对事务: %s\n' "$recovery" "$tx_transaction" >&2
            rc=60
        fi
        (( rc != 0 )) || rc=40
    fi
    rmdir "$tx_state/operation-lock" || rc=60
    exit "$rc"
}

firewall_tx_run() (
    umask 077
    local action=$1 transaction rc=0
    # Subshell-scoped (not function-local): Bash may unwind locals on TERM
    # before running the EXIT trap.
    tx_state=''
    tx_transaction=''
    tx_armed=no
    shift
    vps_require_root || return $?
    tx_state=$(vps_module_state_dir "$MODULE_ID") || return 40
    [[ "$tx_state" == /* && "$tx_state" != *'/../'* &&
       ! -L "$tx_state" && ! -L "$tx_state/transactions" ]] || return 40
    mkdir -p "$tx_state" || return 40
    [[ ! -L "$tx_state/pending_transaction" ]] || return 40
    mkdir "$tx_state/operation-lock" || {
        printf '模块操作锁存在，请先核对未完成操作。\n' >&2
        return 40
    }
    trap 'firewall_tx_finish $?' EXIT
    trap 'printf "操作中断，保留恢复证据。\n" >&2; exit 40' HUP INT TERM
    if [[ "$action" == rollback ]]; then
        if [[ -f "$tx_state/pending_transaction" ]]; then
            IFS= read -r transaction < "$tx_state/pending_transaction" || return 60
            case "$transaction" in "$tx_state"/transactions/*) ;; *) return 60 ;; esac
            [[ "$transaction" != *'/../'* && ! -L "$transaction" && -d "$transaction" ]] || return 60
        else
            transaction=$(vps_last_transaction "$MODULE_ID") || return 60
        fi
        if [[ -f "$transaction/phase" ]] && grep -Eq '^(rolled_back|compensated)$' "$transaction/phase"; then
            rm -f "$tx_state/pending_transaction" || return 60
            printf '本次操作已回滚，无需重复修改。\n'
            return 0
        fi
        printf '%s\n' "$transaction" > "$tx_state/pending_transaction" || return 60
        firewall_tx_phase "$transaction" rollback_pending || return 60
        firewall_rollback_dir "$transaction" || rc=$?
        if (( rc != 0 )); then
            printf '回滚未完成，保留现状和事务证据，请人工核对: %s\n' "$transaction" >&2
            return "$rc"
        fi
        firewall_tx_phase "$transaction" rolled_back || return 60
        rm -f "$tx_state/pending_transaction" || return 60
        return 0
    fi
    if [[ -e "$tx_state/pending_transaction" ]]; then
        printf '存在未完成恢复记录，请先核对并执行 rollback；停止新操作。\n' >&2
        return 40
    fi
    "firewall_${action}_impl" "$@" || return $?
    if [[ "$tx_armed" == yes ]]; then
        firewall_tx_phase "$tx_transaction" committed || return 40
        rm -f "$tx_state/pending_transaction" || return 40
        tx_armed=no
        if [[ "$action" == persistence_configure ]]; then
            printf 'UFW 已成为唯一已启用的防火墙开机所有者，运行规则已重新加载。\n'
        fi
        printf '配置完成。事务记录: %s\n' "$tx_transaction"
    fi
)

firewall_apply() { firewall_tx_run apply; }
firewall_rollback() { firewall_tx_run rollback; }
