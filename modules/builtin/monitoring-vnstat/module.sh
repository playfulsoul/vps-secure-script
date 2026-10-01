#!/usr/bin/env bash

set -u

MODULE_DIR=${VPS_MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
VPS_PLATFORM_ROOT=${VPS_PLATFORM_ROOT:-$(cd -- "$MODULE_DIR/../../.." && pwd)}

# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"
# shellcheck source=../../../core/packages.sh
source "$VPS_PLATFORM_ROOT/core/packages.sh"

TRAFFIC_CONFIG=${VPS_TRAFFIC_CONFIG:-/etc/vps-secure/traffic-quota.conf}
TRAFFIC_MARKER='# Managed by VPS Secure: monitoring.vnstat'

traffic_arguments() {
    TRAFFIC_INTERFACE=''
    TRAFFIC_QUOTA=''
    TRAFFIC_QUOTA_UNIT=''
    TRAFFIC_RESET=''
    TRAFFIC_WARN=''
    TRAFFIC_CRITICAL=''
    while (( $# > 0 )); do
        case $1 in
            --interface|--quota-gib|--quota-gb|--reset-day|--warn-percent|--critical-percent)
                (( $# >= 2 )) || { printf '流量额度参数缺少值: %s\n' "$1" >&2; return 64; }
                ;;
        esac
        case $1 in
            --interface) TRAFFIC_INTERFACE=${2:-}; shift 2 ;;
            --quota-gib|--quota-gb)
                [[ -z "$TRAFFIC_QUOTA_UNIT" ]] || { printf '额度单位只能指定一次。\n' >&2; return 64; }
                TRAFFIC_QUOTA_UNIT=${1#--quota-}
                TRAFFIC_QUOTA=${2:-}; shift 2 ;;
            --reset-day) TRAFFIC_RESET=${2:-}; shift 2 ;;
            --warn-percent) TRAFFIC_WARN=${2:-}; shift 2 ;;
            --critical-percent) TRAFFIC_CRITICAL=${2:-}; shift 2 ;;
            *) printf '未知流量额度参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    [[ "$TRAFFIC_INTERFACE" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,31}$ ]] || {
        printf '网卡名称无效。\n' >&2; return 64;
    }
    [[ "$TRAFFIC_QUOTA" =~ ^[1-9][0-9]{0,5}$ && -n "$TRAFFIC_QUOTA_UNIT" ]] || {
        printf '额度必须是 1–999999 GB 或 GiB 的整数。\n' >&2; return 64;
    }
    [[ "$TRAFFIC_RESET" =~ ^([1-9]|[12][0-9]|3[01])$ ]] || {
        printf '重置日必须是 1–31。\n' >&2; return 64;
    }
    [[ "$TRAFFIC_WARN" =~ ^[1-9][0-9]?$ && "$TRAFFIC_CRITICAL" =~ ^[1-9][0-9]?$ ]] || {
        printf '告警阈值必须是 1–99%%。\n' >&2; return 64;
    }
    (( TRAFFIC_WARN < TRAFFIC_CRITICAL && TRAFFIC_CRITICAL < 100 )) || {
        printf '预警阈值必须低于严重阈值，且均小于 100%%。\n' >&2; return 64;
    }
}

traffic_config_read() {
    local key=$1
    [[ -f "$TRAFFIC_CONFIG" && ! -L "$TRAFFIC_CONFIG" ]] || return 1
    sed -n "s/^$key=//p" "$TRAFFIC_CONFIG" | head -n 1
}

traffic_check() {
    command -v vnstat >/dev/null 2>&1 || { printf '缺少 vnStat。\n' >&2; return 20; }
    command -v python3 >/dev/null 2>&1 || { printf '缺少 Python 3。\n' >&2; return 20; }
}

traffic_plan() {
    traffic_arguments "$@" || return $?
    local display_unit=GB
    [[ "$TRAFFIC_QUOTA_UNIT" == gib ]] && display_unit=GiB
    printf '月度流量额度配置：网卡 %s，额度 %s %s，重置日 %s，阈值 %s%% / %s%%。\n' \
        "$TRAFFIC_INTERFACE" "$TRAFFIC_QUOTA" "$display_unit" "$TRAFFIC_RESET" "$TRAFFIC_WARN" "$TRAFFIC_CRITICAL"
    printf '统计来自本机 vnStat 日记录；不会更改 vnStat 全局月度重置规则。\n'
    printf '不保证与服务商账单一致，初始账期或记录中断会提示数据不完整。\n'
}

traffic_apply() {
    local directory temporary mode existing_marker
    vps_require_root || return $?
    traffic_arguments "$@" || return $?
    command -v python3 >/dev/null 2>&1 || { printf '缺少 Python 3。\n' >&2; return 20; }
    [[ ! -L "$TRAFFIC_CONFIG" ]] || {
        printf '目标配置是符号链接，已停止。\n' >&2; return 30;
    }
    directory=$(dirname -- "$TRAFFIC_CONFIG")
    [[ ! -L "$directory" ]] || { printf '配置目录是符号链接，已停止。\n' >&2; return 30; }
    if [[ -e "$TRAFFIC_CONFIG" ]]; then
        [[ -f "$TRAFFIC_CONFIG" ]] && IFS= read -r existing_marker < "$TRAFFIC_CONFIG" && \
            [[ "$existing_marker" == "$TRAFFIC_MARKER" ]] || {
            printf '现有额度配置不是本模块创建的，已停止以避免覆盖。\n' >&2; return 30;
        }
        mode=$(stat -c %a "$TRAFFIC_CONFIG" 2>/dev/null || stat -f %Lp "$TRAFFIC_CONFIG") || return 30
        (( (8#$mode & 077) == 0 )) || { printf '现有额度配置权限过宽，已停止。\n' >&2; return 30; }
    fi
    if ! command -v vnstat >/dev/null 2>&1; then
        vps_apt_update || return 40
        vps_apt_install vnstat || return 40
    fi
    vnstat --json d 1 -i "$TRAFFIC_INTERFACE" >/dev/null || {
        printf 'vnStat 尚未采集该网卡，未写入额度配置。\n' >&2
        return 30
    }
    if [[ ! -d "$directory" ]]; then
        install -d -m 700 "$directory" || return 40
    fi
    temporary=$(mktemp "$directory/.traffic-quota.XXXXXX") || return 40
    if ! printf '%s\ninterface=%s\nquota_%s=%s\nreset_day=%s\nwarn_percent=%s\ncritical_percent=%s\n' \
        "$TRAFFIC_MARKER" "$TRAFFIC_INTERFACE" "$TRAFFIC_QUOTA_UNIT" "$TRAFFIC_QUOTA" "$TRAFFIC_RESET" "$TRAFFIC_WARN" "$TRAFFIC_CRITICAL" > "$temporary" || \
       ! chmod 600 "$temporary" || ! mv -- "$temporary" "$TRAFFIC_CONFIG"; then
        rm -f -- "$temporary"
        return 40
    fi
    printf '本机月度流量额度已保存；请用 vps monitor traffic status 查看当前账期。\n'
}

traffic_status() {
    local interface quota quota_unit reset warn critical
    [[ $# -eq 0 ]] || return 64
    traffic_check || return $?
    interface=$(traffic_config_read interface) || { printf '尚未配置月度流量额度。\n' >&2; return 30; }
    if quota=$(traffic_config_read quota_gb) && [[ -n "$quota" ]]; then
        quota_unit=gb
    else
        quota=$(traffic_config_read quota_gib) || return 30
        quota_unit=gib
    fi
    reset=$(traffic_config_read reset_day) || return 30
    warn=$(traffic_config_read warn_percent) || return 30
    critical=$(traffic_config_read critical_percent) || return 30
    traffic_arguments --interface "$interface" "--quota-$quota_unit" "$quota" --reset-day "$reset" \
        --warn-percent "$warn" --critical-percent "$critical" || return 30
    vnstat --json d 0 -i "$interface" | python3 "$MODULE_DIR/traffic.py" \
        --interface "$interface" "--quota-$quota_unit" "$quota" --reset-day "$reset" \
        --warn-percent "$warn" --critical-percent "$critical"
}

traffic_main() {
    local action=${1:-status}
    shift || true
    case $action in
        check) traffic_check ;;
        plan) traffic_plan "$@" ;;
        apply) traffic_apply "$@" ;;
        status|doctor) traffic_status "$@" ;;
        *) printf 'monitoring.vnstat 不支持操作: %s\n' "$action" >&2; return 64 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    traffic_main "$@"
fi
