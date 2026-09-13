#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/platform.sh
source "$VPS_PLATFORM_ROOT/core/platform.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"
# shellcheck source=../../../core/ssh.sh
source "$VPS_PLATFORM_ROOT/core/ssh.sh"

MODULE_ID=${VPS_MODULE_ID:-security.firewall}
UFW_UNIT=${VPS_UFW_UNIT:-ufw.service}
UFW_DEFAULT_FILE=${VPS_UFW_DEFAULT_FILE:-/etc/default/ufw}
PERSISTENCE_UNITS=${VPS_FIREWALL_PERSISTENCE_UNITS:-netfilter-persistent.service iptables-persistent.service nftables.service firewalld.service iptables.service ip6tables.service}

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
    local ports conflicts
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
    printf '  - 确认 %s 已加入开机启动，并验证当前内核运行规则。\n' "$UFW_UNIT"
    printf '  - 只为已确认的 SSH 端口新增规则；不会自动新增网站端口 80/443。\n'
    printf '  - 现有用户防火墙规则保持不变。\n'
    conflicts=$(firewall_persistence_conflicts)
    if [[ -n "$conflicts" ]]; then
        printf '  - 检测到其他已启用的防火墙持久化服务: %s。\n' \
            "$(printf '%s\n' "$conflicts" | paste -sd, -)"
        printf '  - apply 不会静默切换所有者；请先运行 vps firewall preflight。\n'
    fi
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

firewall_unit_enabled() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet "$1" 2>/dev/null
}

firewall_ufw_service_enabled() {
    firewall_unit_enabled "$UFW_UNIT"
}

firewall_persistence_conflicts() {
    local units=() unit
    read -r -a units <<< "$PERSISTENCE_UNITS"
    for unit in "${units[@]}"; do
        firewall_unit_enabled "$unit" && printf '%s\n' "$unit"
    done
}

firewall_ipv6_enabled() {
    [[ -r "$UFW_DEFAULT_FILE" ]] || return 1
    awk -F= '
        $1 == "IPV6" {
            value = tolower($2)
            gsub(/[[:space:]"'\'' ]/, "", value)
            found = 1
            enabled = (value == "yes")
        }
        END { exit(found && enabled ? 0 : 1) }
    ' "$UFW_DEFAULT_FILE"
}

firewall_chain_jumps_to() {
    local command_name=$1 chain=$2 target=$3
    "$command_name" -S "$chain" 2>/dev/null | awk -v chain="$chain" -v target="$target" '
        $1 == "-A" && $2 == chain {
            for (i = 3; i < NF; i++) {
                if ($i == "-j" && $(i + 1) == target) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

firewall_runtime_rule_in_chain() {
    local command_name=$1 chain=$2 port=$3 protocol=$4
    "$command_name" -S "$chain" 2>/dev/null | awk \
        -v chain="$chain" -v port="$port" -v protocol="$protocol" '
        $1 == "-A" && $2 == chain {
            proto = dport = accept = 0
            for (i = 3; i < NF; i++) {
                if ($i == "-p" && $(i + 1) == protocol) proto = 1
                if ($i == "--dport" && $(i + 1) == port) dport = 1
                if ($i == "-j" && $(i + 1) == "ACCEPT") accept = 1
            }
            if (proto && dport && accept) found = 1
        }
        END { exit(found ? 0 : 1) }
    '
}

firewall_runtime_family_rule_exists() {
    local command_name=$1 prefix=$2 port=$3 protocol=$4
    command -v "$command_name" >/dev/null 2>&1 || return 1
    firewall_chain_jumps_to "$command_name" INPUT "$prefix-before-input" || return 1
    firewall_chain_jumps_to "$command_name" "$prefix-before-input" "$prefix-user-input" || return 1
    firewall_runtime_rule_in_chain "$command_name" "$prefix-user-input" "$port" "$protocol"
}

firewall_runtime_rule_exists() {
    local port=$1 protocol=${2:-tcp}
    firewall_runtime_family_rule_exists iptables ufw "$port" "$protocol" || return 1
    if firewall_ipv6_enabled; then
        firewall_runtime_family_rule_exists ip6tables ufw6 "$port" "$protocol" || return 1
    fi
}

firewall_configured_simple_allow_rules() {
    ufw show added 2>/dev/null | awk '
        $1 == "ufw" && $2 == "allow" {
            if ($3 ~ /^[0-9]+\/(tcp|udp)$/) {
                split($3, rule, "/")
                print rule[1], rule[2]
            } else if ($3 ~ /^[0-9]+$/) {
                print $3, "tcp"
                print $3, "udp"
            }
        }
    '
}

firewall_runtime_config_rules_verify() {
    local port protocol failed=no
    while read -r port protocol; do
        [[ -n "$port" && -n "$protocol" ]] || continue
        if ! firewall_runtime_rule_exists "$port" "$protocol"; then
            printf 'UFW 持久配置存在、但当前内核运行链缺少规则: %s/%s\n' \
                "$port" "$protocol" >&2
            failed=yes
        fi
    done < <(firewall_configured_simple_allow_rules)
    [[ "$failed" == no ]]
}

firewall_preflight() {
    local ports port conflicts result=0
    firewall_check || return $?
    command -v ufw >/dev/null 2>&1 || {
        printf 'UFW 尚未安装。\n' >&2
        return 30
    }
    firewall_is_active || {
        printf 'UFW 配置尚未加载到当前运行规则。\n' >&2
        return 30
    }
    if ! firewall_ufw_service_enabled; then
        printf '%s 未启用，重启后 UFW 规则可能不会恢复。\n' "$UFW_UNIT" >&2
        result=30
    fi
    conflicts=$(firewall_persistence_conflicts)
    if [[ -n "$conflicts" ]]; then
        printf '检测到并行的防火墙持久化服务:\n%s\n' "$conflicts" >&2
        printf '请确认后运行 sudo vps firewall repair-persistence --yes；不会自动卸载软件或清空规则表。\n' >&2
        result=30
    fi
    ports=$(firewall_ports 2>/dev/null || true)
    while IFS= read -r port; do
        [[ -n "$port" ]] || continue
        firewall_rule_exists "$port" || {
            printf 'UFW 持久配置缺少 SSH 规则: %s/tcp\n' "$port" >&2
            result=30
            continue
        }
        firewall_runtime_rule_exists "$port" tcp || {
            printf '当前内核运行链缺少 SSH 规则: %s/tcp\n' "$port" >&2
            result=30
        }
    done <<< "$ports"
    firewall_runtime_config_rules_verify || result=30
    (( result == 0 )) && printf 'UFW 配置、开机所有者和当前内核运行规则预检通过。\n'
    return "$result"
}

firewall_verify() {
    local ports port conflicts

    command -v ufw >/dev/null 2>&1 || {
        printf 'UFW 尚未安装。\n' >&2
        return 50
    }
    firewall_is_active || {
        printf 'UFW 尚未启用。\n' >&2
        return 50
    }
    firewall_ufw_service_enabled || {
        printf '%s 未启用；当前规则可能在重启后丢失。\n' "$UFW_UNIT" >&2
        return 50
    }
    conflicts=$(firewall_persistence_conflicts)
    [[ -z "$conflicts" ]] || {
        printf '发现与 UFW 冲突的开机持久化服务: %s\n' \
            "$(printf '%s\n' "$conflicts" | paste -sd, -)" >&2
        return 50
    }

    ports=$(firewall_ports 2>/dev/null || true)
    [[ -n "$ports" ]] || return 50
    while IFS= read -r port; do
        if ! firewall_rule_exists "$port"; then
            printf '缺少 SSH 防火墙规则: %s/tcp\n' "$port" >&2
            return 50
        fi
        if ! firewall_runtime_rule_exists "$port" tcp; then
            printf 'UFW 显示已允许，但当前内核运行链缺少 SSH 规则: %s/tcp\n' "$port" >&2
            return 50
        fi
    done <<< "$ports"

    firewall_runtime_config_rules_verify || return 50

    printf 'UFW 配置、开机服务与当前内核运行规则均已通过验证。\n'
}

firewall_status() {
    local conflicts
    if ! command -v ufw >/dev/null 2>&1; then
        printf 'UFW 未安装。\n'
        return 10
    fi
    ufw status verbose
    if firewall_ufw_service_enabled; then
        printf 'UFW 开机服务: 已启用\n'
    else
        printf 'UFW 开机服务: 未启用\n'
    fi
    conflicts=$(firewall_persistence_conflicts)
    if [[ -n "$conflicts" ]]; then
        printf '并行持久化服务:\n%s\n' "$conflicts"
    else
        printf '并行持久化服务: 未发现\n'
    fi
}

firewall_restore_ufw_enablement() {
    local original_enabled=$1
    [[ "$original_enabled" == yes ]] && systemctl enable "$UFW_UNIT" >/dev/null 2>&1 && return 0
    [[ "$original_enabled" == no ]] && systemctl disable "$UFW_UNIT" >/dev/null 2>&1 && return 0
    return 60
}

firewall_persistence_rollback_dir() {
    local transaction_dir=$1 original_enabled unit failed=0
    [[ -r "$transaction_dir/original_ufw_enabled" ]] || return 60
    IFS= read -r original_enabled < "$transaction_dir/original_ufw_enabled"
    firewall_restore_ufw_enablement "$original_enabled" || failed=1
    if [[ -r "$transaction_dir/disabled_conflicts" ]]; then
        while IFS= read -r unit; do
            [[ -n "$unit" ]] || continue
            systemctl enable "$unit" >/dev/null 2>&1 || failed=1
        done < "$transaction_dir/disabled_conflicts"
    fi
    (( failed == 0 )) || return 60
    printf '已恢复防火墙开机服务启用状态；为避免中断 SSH，未恢复或刷新整个运行规则表。\n'
    printf '回滚可能重新启用原有的并行持久化服务；重启前请再次运行 vps firewall preflight。\n'
}

firewall_rollback_dir() {
    local transaction_dir=$1
    local original_active added_port current_port retained_current_port=no

    if [[ -r "$transaction_dir/transaction_kind" ]] && \
       grep -Fxq persistence "$transaction_dir/transaction_kind"; then
        firewall_persistence_rollback_dir "$transaction_dir"
        return $?
    fi

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

    if [[ -r "$transaction_dir/original_ufw_enabled" ]]; then
        local original_ufw_enabled
        IFS= read -r original_ufw_enabled < "$transaction_dir/original_ufw_enabled"
        firewall_restore_ufw_enablement "$original_ufw_enabled" || return 60
    fi

    printf '已回滚本模块添加的规则。\n'
}

firewall_backup_runtime() {
    local transaction_dir=$1
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$transaction_dir/iptables.before" 2>/dev/null || true
    fi
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > "$transaction_dir/ip6tables.before" 2>/dev/null || true
    fi
}

firewall_persistence_configure() {
    local transaction_dir original_enabled=no conflicts unit changed=no
    vps_require_root || return $?
    firewall_check || return $?
    command -v ufw >/dev/null 2>&1 || {
        printf '请先安装并启用 UFW。\n' >&2
        return 30
    }
    firewall_is_active || {
        printf 'UFW 尚未启用；请先运行 sudo vps firewall apply --yes。\n' >&2
        return 30
    }
    if firewall_verify >/dev/null 2>&1; then
        printf 'UFW 开机所有者与运行规则已一致，无需修复。\n'
        return 0
    fi

    transaction_dir=$(vps_new_transaction_dir "$MODULE_ID") || return 40
    printf 'persistence\n' > "$transaction_dir/transaction_kind" || return 40
    firewall_ufw_service_enabled && original_enabled=yes
    printf '%s\n' "$original_enabled" > "$transaction_dir/original_ufw_enabled" || return 40
    conflicts=$(firewall_persistence_conflicts)
    printf '%s\n' "$conflicts" | sed '/^$/d' > "$transaction_dir/disabled_conflicts" || return 40
    firewall_backup_runtime "$transaction_dir"

    if [[ "$original_enabled" == no ]]; then
        systemctl enable "$UFW_UNIT" || {
            firewall_persistence_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
            return 40
        }
        changed=yes
    fi
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        if ! systemctl disable "$unit"; then
            firewall_persistence_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
            return 40
        fi
        changed=yes
    done < "$transaction_dir/disabled_conflicts"

    if ! ufw reload; then
        firewall_persistence_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 40
    fi
    changed=yes
    if ! firewall_verify; then
        firewall_persistence_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 50
    fi
    [[ "$changed" == yes ]] || return 0
    vps_set_last_transaction "$MODULE_ID" "$transaction_dir" || return 40
    printf 'UFW 已成为唯一已启用的防火墙开机所有者，运行规则已重新加载。事务记录: %s\n' \
        "$transaction_dir"
}

firewall_apply() {
    local ports port transaction_dir original_active=no original_ufw_enabled=no changed=no conflicts

    vps_require_root || return $?
    firewall_check || return $?
    ports=$(firewall_ports)

    if ! command -v ufw >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update || return 40
        DEBIAN_FRONTEND=noninteractive apt-get install -y ufw || return 40
    fi

    conflicts=$(firewall_persistence_conflicts)
    if [[ -n "$conflicts" ]]; then
        printf '检测到其他已启用的防火墙持久化服务: %s\n' \
            "$(printf '%s\n' "$conflicts" | paste -sd, -)" >&2
        printf '为避免静默切换防火墙所有者，apply 已停止。请先运行 vps firewall preflight。\n' >&2
        return 30
    fi
    if firewall_is_active && ! firewall_runtime_config_rules_verify; then
        printf 'UFW 持久配置与当前运行规则不一致。请运行 vps firewall preflight，确认后执行 repair-persistence。\n' >&2
        return 30
    fi

    transaction_dir=$(vps_new_transaction_dir "$MODULE_ID") || return 40
    printf 'rules\n' > "$transaction_dir/transaction_kind" || return 40
    if firewall_is_active; then
        original_active=yes
    else
        changed=yes
    fi
    printf '%s\n' "$original_active" > "$transaction_dir/original_active" || return 40
    firewall_ufw_service_enabled && original_ufw_enabled=yes
    printf '%s\n' "$original_ufw_enabled" > "$transaction_dir/original_ufw_enabled" || return 40
    : > "$transaction_dir/added_ports" || return 40
    firewall_backup_runtime "$transaction_dir"

    while IFS= read -r port; do
        if firewall_rule_exists "$port"; then
            continue
        fi
        if ! ufw allow "$port/tcp"; then
            firewall_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
            return 40
        fi
        printf '%s\n' "$port" >> "$transaction_dir/added_ports"
        changed=yes
    done <<< "$ports"

    if [[ "$original_active" == no ]] && ! ufw --force enable; then
        firewall_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 40
    fi
    if [[ "$original_ufw_enabled" == no ]]; then
        if ! systemctl enable "$UFW_UNIT"; then
            firewall_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
            return 40
        fi
        changed=yes
    fi

    if ! firewall_verify; then
        firewall_rollback_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 50
    fi

    if [[ "$changed" == no ]]; then
        rm -f \
            "$transaction_dir/transaction_kind" \
            "$transaction_dir/original_active" \
            "$transaction_dir/original_ufw_enabled" \
            "$transaction_dir/added_ports" \
            "$transaction_dir/iptables.before" \
            "$transaction_dir/ip6tables.before"
        rmdir "$transaction_dir" 2>/dev/null || true
        printf '防火墙已符合执行计划；未创建新事务，保留现有回滚点。\n'
        return 0
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
    preflight) firewall_preflight ;;
    apply) firewall_apply ;;
    configure) firewall_persistence_configure ;;
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
