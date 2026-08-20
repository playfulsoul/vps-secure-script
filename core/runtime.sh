#!/usr/bin/env bash

vps_state_root() {
    printf '%s\n' "${VPS_STATE_DIR:-/var/lib/vps-secure}"
}

vps_timestamp() {
    date -u +%Y%m%dT%H%M%SZ
}

vps_module_state_dir() {
    local module_id=$1
    local safe_id=${module_id//./-}
    printf '%s/modules/%s\n' "$(vps_state_root)" "$safe_id"
}

vps_new_transaction_dir() {
    local module_id=$1
    local state_root module_state transaction_dir

    state_root=$(vps_state_root)
    module_state=$(vps_module_state_dir "$module_id")
    transaction_dir="$module_state/transactions/$(vps_timestamp)-$$"
    mkdir -p "$transaction_dir" || return 1
    chmod 700 "$state_root" "$state_root/modules" "$module_state" \
        "$module_state/transactions" "$transaction_dir" || return 1
    printf '%s\n' "$transaction_dir"
}

vps_set_last_transaction() {
    local module_id=$1
    local transaction_dir=$2
    local module_state temporary

    module_state=$(vps_module_state_dir "$module_id")
    mkdir -p "$module_state" || return 1
    chmod 700 "$(vps_state_root)" "$(vps_state_root)/modules" "$module_state" || return 1
    temporary="$module_state/.last_transaction.$$"
    printf '%s\n' "$transaction_dir" > "$temporary" || return 1
    mv -f "$temporary" "$module_state/last_transaction"
}

vps_last_transaction() {
    local module_id=$1
    local module_state transaction_dir

    module_state=$(vps_module_state_dir "$module_id")
    [[ -r "$module_state/last_transaction" ]] || return 1
    IFS= read -r transaction_dir < "$module_state/last_transaction"

    case "$transaction_dir" in
        "$module_state"/transactions/*)
            [[ -d "$transaction_dir" ]] || return 1
            printf '%s\n' "$transaction_dir"
            ;;
        *)
            printf '拒绝使用模块状态目录之外的事务路径。\n' >&2
            return 1
            ;;
    esac
}

vps_require_root() {
    if (( EUID != 0 )); then
        printf '此操作需要 root 权限。\n' >&2
        return 30
    fi
}
