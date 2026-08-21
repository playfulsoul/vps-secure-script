#!/usr/bin/env bash

set -u

MODULE_DIR=${VPS_MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
VPS_PLATFORM_ROOT=${VPS_PLATFORM_ROOT:-$(cd -- "$MODULE_DIR/../../.." && pwd)}

# shellcheck source=../../../core/packages.sh
source "$VPS_PLATFORM_ROOT/core/packages.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

CONFIG_FILE=${VPS_MONITOR_CONFIG:-/etc/vps-secure/network-monitor.conf}
DATA_DIR=${VPS_MONITOR_DATA_DIR:-$(vps_state_root)/monitoring/network}
METRICS_FILE=$DATA_DIR/metrics.tsv
SERVICE_FILE=${VPS_MONITOR_SERVICE:-/etc/systemd/system/vps-network-monitor.service}
TIMER_FILE=${VPS_MONITOR_TIMER:-/etc/systemd/system/vps-network-monitor.timer}

monitor_config_value() {
    local key=$1 line
    [[ -r "$CONFIG_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] || continue
        printf '%s\n' "${line#*=}"
        return 0
    done < "$CONFIG_FILE"
    return 1
}

monitor_target_valid() {
    [[ ${1:-} =~ ^([a-zA-Z0-9][a-zA-Z0-9.-]{0,252}|[0-9a-fA-F:]{2,39})$ ]]
}

monitor_arguments() {
    local target=1.1.1.1 interval=60 retention=30
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) target=${2:-}; shift 2 ;;
            --interval) interval=${2:-}; shift 2 ;;
            --retention-days) retention=${2:-}; shift 2 ;;
            *) printf '未知参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    monitor_target_valid "$target" || { printf '监控目标格式无效。\n' >&2; return 64; }
    if [[ ! "$interval" =~ ^[0-9]+$ ]] || (( interval < 15 || interval > 86400 )); then
        printf '采集间隔必须在 15 到 86400 秒之间。\n' >&2
        return 64
    fi
    if [[ ! "$retention" =~ ^[0-9]+$ ]] || (( retention < 1 || retention > 3650 )); then
        printf '保留天数必须在 1 到 3650 之间。\n' >&2
        return 64
    fi
    printf '%s %s %s\n' "$target" "$interval" "$retention"
}

monitor_check() {
    command -v ping >/dev/null 2>&1 || { printf '缺少 ping。\n' >&2; return 20; }
    command -v ip >/dev/null 2>&1 || { printf '缺少 iproute2。\n' >&2; return 20; }
}

monitor_ensure_dependencies() {
    monitor_check >/dev/null 2>&1 && return 0
    vps_require_root || {
        printf '网络检测缺少必要组件，请使用 sudo vps 后重试。\n' >&2
        return 30
    }
    vps_apt_update || return 40
    vps_apt_install iproute2 iputils-ping || return 40
    monitor_check
}

monitor_plan() {
    local target interval retention
    read -r target interval retention <<< "$(monitor_arguments "$@")" || return $?
    printf '网络监控执行计划：\n'
    printf '  - 目标: %s\n' "$target"
    printf '  - 间隔: %s 秒\n' "$interval"
    printf '  - 数据保留: %s 天\n' "$retention"
    printf '  - 每次发送 5 个 ICMP 请求，记录延迟和丢包。\n'
    printf '  - 同时记录默认网卡累计收发字节；至少两次采样后计算平均速率。\n'
    printf '  - 不自动运行高流量互联网带宽测试。\n'
}

monitor_write_units() {
    local interval=$1
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS Secure network metrics collection
After=network-online.target

[Service]
Type=oneshot
ExecStart=$MODULE_DIR/module.sh collect
EOF
    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Collect VPS network metrics periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=${interval}s
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

monitor_configure() {
    local target interval retention config_dir
    vps_require_root || return $?
    read -r target interval retention <<< "$(monitor_arguments "$@")" || return $?
    monitor_check || {
        vps_apt_update || return 40
        vps_apt_install iproute2 iputils-ping || return 40
    }
    config_dir=$(dirname -- "$CONFIG_FILE")
    install -d -m 755 "$config_dir" || return 40
    install -d -m 700 "$DATA_DIR" || return 40
    printf '%s\n' \
        "target=$target" \
        "interval=$interval" \
        "retention_days=$retention" > "$CONFIG_FILE" || return 40
    chmod 600 "$CONFIG_FILE" || return 40
    monitor_write_units "$interval" || return 40
    systemctl daemon-reload || return 40
    systemctl enable --now vps-network-monitor.timer || return 40
    printf '网络监控已配置并启动。\n'
}

monitor_collect() {
    local target retention now iso output sent received loss average interface rx_bytes tx_bytes
    local temporary cutoff target_override=''
    while [[ $# -gt 0 ]]; do
        case $1 in
            --target) target_override=${2:-}; shift 2 ;;
            *) printf '未知参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    monitor_check || return $?
    if [[ -n "$target_override" ]]; then
        monitor_target_valid "$target_override" || {
            printf '检测目标格式无效。\n' >&2
            return 64
        }
        target=$target_override
    else
        target=$(monitor_config_value target 2>/dev/null || printf '1.1.1.1')
    fi
    retention=$(monitor_config_value retention_days 2>/dev/null || printf 30)
    now=$(date +%s)
    iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    output=$(LC_ALL=C ping -c 5 -W 3 "$target" 2>&1 || true)
    sent=$(printf '%s\n' "$output" | awk '/packets transmitted/ {print $1; exit}')
    received=$(printf '%s\n' "$output" | awk '/packets transmitted/ {print $4; exit}')
    loss=$(printf '%s\n' "$output" | sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p' | head -n1)
    average=$(printf '%s\n' "$output" | awk -F'= ' '/^(rtt|round-trip)/ {split($2, a, "/"); print a[2]; exit}')
    sent=${sent:-5}
    received=${received:-0}
    loss=${loss:-100}
    average=${average:-NA}

    interface=$(ip route show default 2>/dev/null | awk '/default/ {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    if [[ -n "$interface" && -r "/sys/class/net/$interface/statistics/rx_bytes" ]]; then
        rx_bytes=$(<"/sys/class/net/$interface/statistics/rx_bytes")
        tx_bytes=$(<"/sys/class/net/$interface/statistics/tx_bytes")
    else
        interface=unknown
        rx_bytes=0
        tx_bytes=0
    fi

    install -d -m 700 "$DATA_DIR" || return 40
    if [[ ! -f "$METRICS_FILE" ]]; then
        printf 'epoch\ttime\ttarget\tsent\treceived\tloss_percent\tavg_ms\tinterface\trx_bytes\ttx_bytes\n' > "$METRICS_FILE"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$now" "$iso" "$target" "$sent" "$received" "$loss" "$average" "$interface" "$rx_bytes" "$tx_bytes" >> "$METRICS_FILE"

    cutoff=$((now - retention * 86400))
    temporary="$DATA_DIR/.metrics.$$"
    awk -F'\t' -v cutoff="$cutoff" 'NR == 1 || $1 >= cutoff' "$METRICS_FILE" > "$temporary" && \
        mv "$temporary" "$METRICS_FILE"
}

monitor_format_bytes() {
    awk -v bytes="${1:-0}" 'BEGIN {
        split("B KB MB GB TB", unit, " ")
        value = bytes + 0
        unit_index = 1
        while (value >= 1024 && unit_index < 5) { value /= 1024; unit_index++ }
        if (unit_index == 1) printf "%.0f %s", value, unit[unit_index]
        else printf "%.2f %s", value, unit[unit_index]
    }'
}

monitor_quality_label() {
    local loss=$1 average=$2
    if [[ "$average" == NA ]] || awk -v value="$loss" 'BEGIN { exit !(value >= 100) }'; then
        printf '无法连接'
    elif awk -v value="$loss" 'BEGIN { exit !(value > 0) }'; then
        printf '存在丢包'
    elif awk -v value="$average" 'BEGIN { exit !(value < 50) }'; then
        printf '良好'
    elif awk -v value="$average" 'BEGIN { exit !(value < 120) }'; then
        printf '一般'
    else
        printf '延迟较高'
    fi
}

monitor_latest_rate() {
    local previous current
    local p_epoch p_interface p_rx p_tx
    local c_epoch c_interface c_rx c_tx
    previous=$(tail -n 2 "$METRICS_FILE" 2>/dev/null | head -n 1)
    current=$(tail -n 1 "$METRICS_FILE" 2>/dev/null)
    if [[ -z "$previous" || "$previous" == epoch$'\t'* || "$previous" == "$current" ]]; then
        printf '平均速率：需要至少两次采样\n'
        return 0
    fi
    IFS=$'\t' read -r p_epoch _ _ _ _ _ _ p_interface p_rx p_tx <<< "$previous"
    IFS=$'\t' read -r c_epoch _ _ _ _ _ _ c_interface c_rx c_tx <<< "$current"
    if [[ "$p_interface" != "$c_interface" || "$c_interface" == unknown ]] || \
       (( c_epoch <= p_epoch || c_rx < p_rx || c_tx < p_tx )); then
        printf '平均速率：暂时无法计算\n'
        return 0
    fi
    awk -v seconds="$((c_epoch - p_epoch))" -v rx="$((c_rx - p_rx))" -v tx="$((c_tx - p_tx))" \
        'BEGIN { printf "采样间平均速率：下载 %.2f Mbps｜上传 %.2f Mbps\n", rx * 8 / seconds / 1000000, tx * 8 / seconds / 1000000 }'
}

monitor_status() {
    local latest iso target sent received loss average interface rx_bytes tx_bytes timer_state
    if [[ ! -r "$METRICS_FILE" ]]; then
        printf '尚无网络检测数据。请先运行一次“立即检测网络状态”。\n'
        return 10
    fi
    latest=$(tail -n 1 "$METRICS_FILE")
    IFS=$'\t' read -r _ iso target sent received loss average interface rx_bytes tx_bytes <<< "$latest"
    printf '最近一次网络检测\n\n'
    printf '检测时间：%s\n' "$iso"
    printf '检测目标：%s\n' "$target"
    printf '平均延迟：%s ms\n' "$average"
    printf '丢包率：%s%%（发送 %s，收到 %s）\n' "$loss" "$sent" "$received"
    printf '网络状态：%s\n' "$(monitor_quality_label "$loss" "$average")"
    printf '默认网卡：%s\n' "$interface"
    printf '累计接收：%s\n' "$(monitor_format_bytes "$rx_bytes")"
    printf '累计发送：%s\n' "$(monitor_format_bytes "$tx_bytes")"
    monitor_latest_rate
    if command -v systemctl >/dev/null 2>&1; then
        timer_state=$(systemctl is-active vps-network-monitor.timer 2>/dev/null || true)
        printf '\n定时器状态: %s\n' "${timer_state:-inactive}"
    fi
}

monitor_apply() {
    vps_require_root || return $?
    monitor_ensure_dependencies || return $?
    monitor_collect "$@" || return $?
    monitor_status
}

monitor_verify() {
    [[ -r "$CONFIG_FILE" ]] || return 50
    systemctl is-enabled --quiet vps-network-monitor.timer || return 50
    systemctl is-active --quiet vps-network-monitor.timer || return 50
    printf '网络监控配置和定时器已通过验证。\n'
}

monitor_start() {
    vps_require_root || return $?
    systemctl enable --now vps-network-monitor.timer
}

monitor_stop() {
    vps_require_root || return $?
    systemctl disable --now vps-network-monitor.timer
}

case ${1:-} in
    check) monitor_check ;;
    plan) shift; monitor_plan "$@" ;;
    configure) shift; monitor_configure "$@" ;;
    apply) shift; monitor_apply "$@" ;;
    collect) shift; monitor_collect "$@" ;;
    status|doctor) monitor_status ;;
    verify) monitor_verify ;;
    start) monitor_start ;;
    stop) monitor_stop ;;
    *) printf 'monitoring.network 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
