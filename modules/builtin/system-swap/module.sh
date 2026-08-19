#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

MODULE_ID=${VPS_MODULE_ID:-system.swap}
SWAP_FILE=${VPS_SWAP_FILE:-/swapfile}
FSTAB_FILE=${VPS_FSTAB_FILE:-/etc/fstab}

swap_size() {
    local size=1G
    if [[ ${1:-} == --size ]]; then
        size=${2:-}
    fi
    [[ "$size" =~ ^[1-9][0-9]*[MG]$ ]] || {
        printf 'Swap 大小格式无效，请使用例如 512M 或 2G。\n' >&2
        return 64
    }
    printf '%s\n' "$size"
}

swap_check() {
    command -v swapon >/dev/null 2>&1 && command -v mkswap >/dev/null 2>&1 || return 20
    [[ -r "$FSTAB_FILE" ]] || return 30
}

swap_status() {
    if swapon --noheadings --show=NAME,SIZE,USED 2>/dev/null | grep -q .; then
        swapon --show=NAME,SIZE,USED,PRIO
    else
        printf '当前未启用 Swap。\n'
        return 10
    fi
}

swap_plan() {
    local size
    swap_check || return $?
    size=$(swap_size "$@") || return $?
    printf 'Swap 执行计划：\n'
    printf '  - 目标文件: %s\n' "$SWAP_FILE"
    printf '  - 大小: %s\n' "$size"
    printf '  - 已存在任何 Swap 时安全跳过。\n'
    printf '  - 未启用但已存在目标文件时停止，不覆盖未知数据。\n'
}

swap_verify() {
    swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$SWAP_FILE" || {
        printf 'Swap 文件未处于启用状态。\n' >&2
        return 50
    }
    grep -Fqx "$SWAP_FILE none swap sw 0 0" "$FSTAB_FILE" || {
        printf 'fstab 中缺少 Swap 持久化记录。\n' >&2
        return 50
    }
    printf 'Swap 已启用并写入持久配置。\n'
}

swap_rollback_dir() {
    local transaction_dir=$1
    swapoff "$SWAP_FILE" 2>/dev/null || true
    [[ ! -f "$transaction_dir/fstab.before" ]] || \
        cp "$transaction_dir/fstab.before" "$FSTAB_FILE" || return 60
    rm -f "$SWAP_FILE" || return 60
}

swap_apply() {
    local size transaction_dir count_mb
    vps_require_root || return $?
    swap_check || return $?
    size=$(swap_size "$@") || return $?

    if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
        printf '系统已有 Swap，本次跳过。\n'
        return 10
    fi
    [[ ! -e "$SWAP_FILE" ]] || {
        printf '目标文件已存在但未启用，拒绝覆盖: %s\n' "$SWAP_FILE" >&2
        return 30
    }

    transaction_dir=$(vps_new_transaction_dir "$MODULE_ID") || return 40
    cp "$FSTAB_FILE" "$transaction_dir/fstab.before" || return 40

    if ! fallocate -l "$size" "$SWAP_FILE" 2>/dev/null; then
        if [[ "$size" == *G ]]; then
            count_mb=$((${size%G} * 1024))
        else
            count_mb=${size%M}
        fi
        if ! dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$count_mb" status=progress; then
            swap_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
            return 40
        fi
    fi
    chmod 600 "$SWAP_FILE" || { swap_rollback_dir "$transaction_dir"; return 40; }
    mkswap "$SWAP_FILE" || { swap_rollback_dir "$transaction_dir"; return 40; }
    swapon "$SWAP_FILE" || { swap_rollback_dir "$transaction_dir"; return 40; }
    if ! grep -Fqx "$SWAP_FILE none swap sw 0 0" "$FSTAB_FILE"; then
        printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> "$FSTAB_FILE" || {
            swap_rollback_dir "$transaction_dir"
            return 40
        }
    fi

    if ! swap_verify; then
        swap_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 50
    fi
    vps_set_last_transaction "$MODULE_ID" "$transaction_dir" || return 40
}

swap_rollback() {
    local transaction_dir
    vps_require_root || return $?
    transaction_dir=$(vps_last_transaction "$MODULE_ID") || return 60
    [[ -f "$transaction_dir/fstab.before" ]] || return 60
    swap_rollback_dir "$transaction_dir" || return $?
    printf 'Swap 模块变更已回滚。\n'
}

case ${1:-} in
    check) swap_check ;;
    plan) shift; swap_plan "$@" ;;
    status|doctor) swap_status ;;
    apply) shift; swap_apply "$@" ;;
    verify) swap_verify ;;
    rollback) swap_rollback ;;
    *) printf 'system.swap 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
