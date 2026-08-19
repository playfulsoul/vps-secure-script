#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/ssh.sh
source "$VPS_PLATFORM_ROOT/core/ssh.sh"

ssh_check() {
    if ! vps_find_sshd >/dev/null 2>&1; then
        printf '[FAIL] 未找到 sshd。\n' >&2
        return 20
    fi
}

ssh_status() {
    local current_port ports

    ssh_check || return $?

    current_port=$(vps_ssh_connection_port 2>/dev/null || true)
    ports=$(vps_require_ssh_ports 2>/dev/null || true)

    if [[ -n "$current_port" ]]; then
        printf '当前 SSH 会话端口: %s\n' "$current_port"
    else
        printf '当前 SSH 会话端口: 未检测到 SSH 会话\n'
    fi

    if [[ -z "$ports" ]]; then
        printf '生效 SSH 端口: 无法可靠确认\n' >&2
        return 30
    fi

    printf '已确认 SSH 端口: %s\n' "$(printf '%s\n' "$ports" | paste -sd, -)"
    printf '策略: 保持现有端口；不会自动回退到 22。\n'
}

case ${1:-} in
    check)
        ssh_check
        ;;
    status|doctor)
        ssh_status
        ;;
    plan|apply|backup|rollback|verify|configure)
        printf 'SSH 修改功能尚未迁移到模块化执行器。\n' >&2
        exit 20
        ;;
    *)
        printf 'security.ssh 不支持操作: %s\n' "${1:-}" >&2
        exit 64
        ;;
esac
