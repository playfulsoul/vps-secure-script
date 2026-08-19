#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

MODULE_ID=${VPS_MODULE_ID:-system.bbr}
CONFIG_FILE=${VPS_BBR_CONFIG:-/etc/sysctl.d/90-vps-secure-bbr.conf}

bbr_available() {
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
}

bbr_check() {
    command -v sysctl >/dev/null 2>&1 || return 20
    bbr_available || {
        printf '当前内核未提供 BBR。\n' >&2
        return 20
    }
}

bbr_status() {
    printf '当前拥塞控制: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
    printf '可用算法: %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf unknown)"
}

bbr_plan() {
    bbr_check || return $?
    printf 'BBR 执行计划：\n'
    printf '  - 写入模块自有配置: %s\n' "$CONFIG_FILE"
    printf '  - 设置 default_qdisc=fq 和 tcp_congestion_control=bbr。\n'
    printf '  - 应用后读取内核实际值进行验证。\n'
}

bbr_verify() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qx bbr || return 50
    printf 'BBR 已启用。\n'
}

bbr_apply() {
    local transaction_dir config_dir
    vps_require_root || return $?
    bbr_check || return $?
    transaction_dir=$(vps_new_transaction_dir "$MODULE_ID") || return 40
    sysctl -n net.core.default_qdisc > "$transaction_dir/previous_qdisc" 2>/dev/null || true
    sysctl -n net.ipv4.tcp_congestion_control > "$transaction_dir/previous_cc" 2>/dev/null || true
    config_dir=$(dirname -- "$CONFIG_FILE")
    install -d -m 755 "$config_dir" || return 40
    if [[ -f "$CONFIG_FILE" ]]; then
        printf 'yes\n' > "$transaction_dir/config_existed"
        cp "$CONFIG_FILE" "$transaction_dir/original.conf" || return 40
    else
        printf 'no\n' > "$transaction_dir/config_existed"
    fi
    printf '%s\n' \
        'net.core.default_qdisc=fq' \
        'net.ipv4.tcp_congestion_control=bbr' > "$CONFIG_FILE" || return 40
    if ! sysctl --system >/dev/null || ! bbr_verify; then
        bbr_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 50
    fi
    vps_set_last_transaction "$MODULE_ID" "$transaction_dir" || return 40
}

bbr_rollback_dir() {
    local transaction_dir=$1 existed previous
    IFS= read -r existed < "$transaction_dir/config_existed" || return 60
    if [[ "$existed" == yes ]]; then
        cp "$transaction_dir/original.conf" "$CONFIG_FILE" || return 60
    else
        rm -f "$CONFIG_FILE" || return 60
    fi
    sysctl --system >/dev/null || return 60
    if [[ -s "$transaction_dir/previous_qdisc" ]]; then
        IFS= read -r previous < "$transaction_dir/previous_qdisc"
        sysctl -w "net.core.default_qdisc=$previous" >/dev/null || return 60
    fi
    if [[ -s "$transaction_dir/previous_cc" ]]; then
        IFS= read -r previous < "$transaction_dir/previous_cc"
        sysctl -w "net.ipv4.tcp_congestion_control=$previous" >/dev/null || return 60
    fi
    printf 'BBR 模块配置已回滚。\n'
}

bbr_rollback() {
    local transaction_dir
    vps_require_root || return $?
    transaction_dir=$(vps_last_transaction "$MODULE_ID") || return 60
    bbr_rollback_dir "$transaction_dir"
}

case ${1:-} in
    check) bbr_check ;;
    plan) bbr_plan ;;
    status|doctor) bbr_status ;;
    apply) bbr_apply ;;
    verify) bbr_verify ;;
    rollback) bbr_rollback ;;
    *) printf 'system.bbr 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
