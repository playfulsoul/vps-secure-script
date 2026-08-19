#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/platform.sh
source "$VPS_PLATFORM_ROOT/core/platform.sh"
# shellcheck source=../../../core/ssh.sh
source "$VPS_PLATFORM_ROOT/core/ssh.sh"

doctor_check() {
    local platform
    platform=$(vps_platform_id 2>/dev/null || true)
    case "$platform" in
        debian|ubuntu)
            return 0
            ;;
        '')
            printf '[FAIL] 无法读取 /etc/os-release。\n' >&2
            return 20
            ;;
        *)
            printf '[WARN] 当前平台 %s 尚未列入正式支持范围。\n' "$platform" >&2
            return 20
            ;;
    esac
}

doctor_run() {
    local warnings=0
    local platform package_manager ssh_ports current_port

    platform=$(vps_platform_label)
    printf '[INFO] 系统: %s\n' "$platform"

    if vps_has_systemd; then
        printf '[OK]   systemd 可用。\n'
    else
        printf '[WARN] 未检测到正在运行的 systemd。\n'
        warnings=$((warnings + 1))
    fi

    package_manager=$(vps_package_manager 2>/dev/null || true)
    if [[ -n "$package_manager" ]]; then
        printf '[OK]   包管理器: %s\n' "$package_manager"
    else
        printf '[WARN] 未检测到受支持的包管理器。\n'
        warnings=$((warnings + 1))
    fi

    current_port=$(vps_ssh_connection_port "${SSH_CONNECTION:-}" 2>/dev/null || true)
    if [[ -n "$current_port" ]]; then
        printf '[OK]   当前 SSH 会话端口: %s\n' "$current_port"
    else
        printf '[INFO] 当前不是可识别的 SSH 会话。\n'
    fi

    ssh_ports=$(vps_require_ssh_ports 2>/dev/null || true)
    if [[ -n "$ssh_ports" ]]; then
        printf '[OK]   已确认 SSH 端口: %s\n' "$(printf '%s\n' "$ssh_ports" | paste -sd, -)"
    else
        printf '[FAIL] 无法确认 SSH 端口；不得自动启用防火墙。\n'
        warnings=$((warnings + 1))
    fi

    if command -v ufw >/dev/null 2>&1; then
        printf '[INFO] 已安装 UFW。\n'
    elif command -v nft >/dev/null 2>&1; then
        printf '[INFO] 已安装 nftables 工具。\n'
    else
        printf '[INFO] 未检测到 UFW 或 nft 命令。\n'
    fi

    if command -v fail2ban-client >/dev/null 2>&1; then
        printf '[INFO] 已安装 Fail2Ban。\n'
    else
        printf '[INFO] 未安装 Fail2Ban。\n'
    fi

    if command -v docker >/dev/null 2>&1; then
        printf '[WARN] 已安装 Docker；发布的容器端口需单独审查防火墙策略。\n'
        warnings=$((warnings + 1))
    fi

    if (( warnings > 0 )); then
        printf '[SUMMARY] 发现 %s 个需要关注的项目。\n' "$warnings"
        return 30
    fi

    printf '[SUMMARY] 未发现阻止安全初始化的问题。\n'
}

case ${1:-} in
    check)
        doctor_check
        ;;
    doctor|status)
        doctor_check || exit $?
        doctor_run
        ;;
    *)
        printf 'system.doctor 不支持操作: %s\n' "${1:-}" >&2
        exit 64
        ;;
esac
