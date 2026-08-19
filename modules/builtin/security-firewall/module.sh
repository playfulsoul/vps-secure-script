#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/platform.sh
source "$VPS_PLATFORM_ROOT/core/platform.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"
# shellcheck source=../../../core/ssh.sh
source "$VPS_PLATFORM_ROOT/core/ssh.sh"

MODULE_ID=${VPS_MODULE_ID:-security.firewall}

firewall_supported_platform() {
    local platform
    platform=$(vps_platform_id 2>/dev/null || true)
    case "$platform" in
        debian|ubuntu) return 0 ;;
        *)
            printf '防火墙模块暂不支持平台: %s\n' "${platform:-unknown}" >&2
            return 20
            ;;
    esac
}

firewall_ports() {
    vps_require_ssh_ports
}

firewall_check() {
    local ports
    firewall_supported_platform || return $?
    ports=$(firewall_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then
        printf '无法可靠确认 SSH 端口；不得自动启用防火墙。\n' >&2
        return 30
    fi
}

firewall_plan() {
    local ports
    firewall_check || return $?
    ports=$(firewall_ports)

    printf '防火墙执行计划：\n'
    if command -v ufw >/dev/null 2>&1; then
        printf '  - 使用已安装的 UFW。\n'
    else
        printf '  - 通过 APT 安装 UFW。\n'
    fi
    printf '  - 保持并放行 SSH 端口: %s。\n' "$(printf '%s\n' "$ports" | paste -sd, -)"
    printf '  - 启用 UFW，并沿用系统现有默认策略。\n'
    printf '  - 只为已确认的 SSH 端口新增规则；不会自动新增网站端口 80/443。\n'
    printf '  - 现有用户防火墙规则保持不变。\n'
}

firewall_is_active() {
    ufw status 2>/dev/null | grep -q '^Status: active$'
}

firewall_rule_exists() {
    local port=$1
    if ufw status 2>/dev/null |
        awk -v rule="$port/tcp" '$1 == rule && $2 == "ALLOW" { found = 1 } END { exit(found ? 0 : 1) }'; then
        return 0
    fi

    ufw show added 2>/dev/null | grep -Fxq "ufw allow $port/tcp"
}

firewall_verify() {
    local ports port

    command -v ufw >/dev/null 2>&1 || {
        printf 'UFW 尚未安装。\n' >&2
        return 50
    }
    firewall_is_active || {
        printf 'UFW 尚未启用。\n' >&2
        return 50
    }

    ports=$(firewall_ports 2>/dev/null || true)
    [[ -n "$ports" ]] || return 50
    while IFS= read -r port; do
        if ! firewall_rule_exists "$port"; then
            printf '缺少 SSH 防火墙规则: %s/tcp\n' "$port" >&2
            return 50
        fi
    done <<< "$ports"

    printf 'UFW 已启用，所有已确认的 SSH 端口均已放行。\n'
}

firewall_status() {
    if ! command -v ufw >/dev/null 2>&1; then
        printf 'UFW 未安装。\n'
        return 10
    fi
    ufw status verbose
}

firewall_rollback_dir() {
    local transaction_dir=$1
    local original_active added_port current_port retained_current_port=no

    [[ -r "$transaction_dir/original_active" ]] || return 60
    IFS= read -r original_active < "$transaction_dir/original_active"

    if [[ "$original_active" == no ]]; then
        ufw --force disable >/dev/null 2>&1 || return 60
    else
        current_port=$(vps_ssh_connection_port "${SSH_CONNECTION:-}" 2>/dev/null || true)
    fi

    if [[ -r "$transaction_dir/added_ports" ]]; then
        while IFS= read -r added_port; do
            [[ -n "$added_port" ]] || continue
            if [[ "$original_active" == yes && "$added_port" == "$current_port" ]]; then
                printf '保留当前 SSH 会话端口规则: %s/tcp；请切换到其他已放行端口后再次回滚。\n' \
                    "$added_port" >&2
                retained_current_port=yes
                continue
            fi
            firewall_rule_exists "$added_port" || continue
            ufw --force delete allow "$added_port/tcp" >/dev/null 2>&1 || return 60
        done < "$transaction_dir/added_ports"
    fi

    if [[ "$retained_current_port" == yes ]]; then
        return 10
    fi

    printf '已回滚本模块添加的规则。\n'
}

firewall_apply() {
    local ports port transaction_dir original_active=no

    vps_require_root || return $?
    firewall_check || return $?
    ports=$(firewall_ports)

    if ! command -v ufw >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update || return 40
        DEBIAN_FRONTEND=noninteractive apt-get install -y ufw || return 40
    fi

    transaction_dir=$(vps_new_transaction_dir "$MODULE_ID") || return 40
    if firewall_is_active; then
        original_active=yes
    fi
    printf '%s\n' "$original_active" > "$transaction_dir/original_active" || return 40
    : > "$transaction_dir/added_ports" || return 40

    while IFS= read -r port; do
        if firewall_rule_exists "$port"; then
            continue
        fi
        if ! ufw allow "$port/tcp"; then
            firewall_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
            return 40
        fi
        printf '%s\n' "$port" >> "$transaction_dir/added_ports"
    done <<< "$ports"

    if ! ufw --force enable; then
        firewall_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 40
    fi

    if ! firewall_verify; then
        firewall_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 50
    fi

    vps_set_last_transaction "$MODULE_ID" "$transaction_dir" || return 40
    printf '防火墙配置完成。事务记录: %s\n' "$transaction_dir"
}

firewall_rollback() {
    local transaction_dir
    vps_require_root || return $?
    transaction_dir=$(vps_last_transaction "$MODULE_ID") || {
        printf '没有可回滚的防火墙事务。\n' >&2
        return 60
    }
    firewall_rollback_dir "$transaction_dir"
}

case ${1:-} in
    check) firewall_check ;;
    plan) firewall_plan ;;
    apply) firewall_apply ;;
    verify) firewall_verify ;;
    status|doctor) firewall_status ;;
    rollback) firewall_rollback ;;
    backup)
        printf '防火墙备份在 apply 操作中自动创建。\n'
        ;;
    *)
        printf 'security.firewall 不支持操作: %s\n' "${1:-}" >&2
        exit 64
        ;;
esac
