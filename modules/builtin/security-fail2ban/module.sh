#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/platform.sh
source "$VPS_PLATFORM_ROOT/core/platform.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"
# shellcheck source=../../../core/ssh.sh
source "$VPS_PLATFORM_ROOT/core/ssh.sh"

MODULE_ID=${VPS_MODULE_ID:-security.fail2ban}
CONFIG_ROOT=${VPS_FAIL2BAN_CONFIG_ROOT:-/etc/fail2ban}
CONFIG_RELATIVE=${VPS_FAIL2BAN_CONFIG_RELATIVE:-jail.d/90-vps-secure.local}
CONFIG_FILE=${VPS_FAIL2BAN_CONFIG:-$CONFIG_ROOT/$CONFIG_RELATIVE}
AUTH_LOG_FILE=${VPS_AUTH_LOG_FILE:-/var/log/auth.log}

fail2ban_supported_platform() {
    local platform
    platform=$(vps_platform_id 2>/dev/null || true)
    case "$platform" in
        debian|ubuntu) return 0 ;;
        *)
            printf 'Fail2Ban 模块暂不支持平台: %s\n' "${platform:-unknown}" >&2
            return 20
            ;;
    esac
}

fail2ban_backend() {
    if command -v journalctl >/dev/null 2>&1 && vps_has_systemd; then
        printf 'systemd\n'
    elif [[ -f "$AUTH_LOG_FILE" ]]; then
        printf 'logfile\n'
    else
        return 1
    fi
}

fail2ban_ports() {
    vps_require_ssh_ports
}

fail2ban_check() {
    local ports backend
    fail2ban_supported_platform || return $?

    ports=$(fail2ban_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then
        printf '无法可靠确认 SSH 端口，不能生成 Fail2Ban jail。\n' >&2
        return 30
    fi

    backend=$(fail2ban_backend 2>/dev/null || true)
    if [[ -z "$backend" ]]; then
        printf '未发现 systemd journal 或 SSH 日志文件 %s。\n' "$AUTH_LOG_FILE" >&2
        return 30
    fi
}

fail2ban_plan() {
    local ports backend
    fail2ban_check || return $?
    ports=$(fail2ban_ports)
    backend=$(fail2ban_backend)

    printf 'Fail2Ban 执行计划：\n'
    if command -v fail2ban-client >/dev/null 2>&1; then
        printf '  - 使用已安装的 Fail2Ban。\n'
    else
        printf '  - 通过 APT 安装 Fail2Ban。\n'
    fi
    printf '  - SSH 端口: %s。\n' "$(printf '%s\n' "$ports" | paste -sd, -)"
    printf '  - 日志后端: %s。\n' "$backend"
    printf '  - 写入模块自有配置: %s。\n' "$CONFIG_FILE"
    printf '  - 不覆盖 /etc/fail2ban/jail.local。\n'
}

fail2ban_write_candidate() {
    local candidate=$1
    local ports_csv=$2
    local backend=$3

    if [[ "$backend" == systemd ]]; then
        cat > "$candidate" <<EOF
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = $ports_csv
backend = systemd
logpath =
EOF
    else
        cat > "$candidate" <<EOF
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = $ports_csv
logpath = $AUTH_LOG_FILE
backend = auto
EOF
    fi
}

fail2ban_preflight() {
    local ports backend ports_csv temporary_dir candidate_file result=0

    fail2ban_check || return $?
    command -v fail2ban-client >/dev/null 2>&1 || {
        printf '尚未安装 Fail2Ban，无法执行真实配置预检。\n' >&2
        return 30
    }
    [[ -d "$CONFIG_ROOT" ]] || {
        printf 'Fail2Ban 配置目录不存在: %s\n' "$CONFIG_ROOT" >&2
        return 30
    }
    case "/$CONFIG_RELATIVE/" in
        *'/../'*|*'//'*)
            printf '模块配置相对路径无效: %s\n' "$CONFIG_RELATIVE" >&2
            return 64
            ;;
    esac

    ports=$(fail2ban_ports) || return $?
    backend=$(fail2ban_backend) || return $?
    ports_csv=$(printf '%s\n' "$ports" | paste -sd, -)
    temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-secure-fail2ban.XXXXXX") || return 30

    if ! cp -a "$CONFIG_ROOT/." "$temporary_dir/"; then
        printf '无法复制 Fail2Ban 配置用于临时预检。\n' >&2
        rm -rf -- "$temporary_dir"
        return 30
    fi
    candidate_file="$temporary_dir/$CONFIG_RELATIVE"
    if ! install -d -m 700 "$(dirname -- "$candidate_file")" || \
       ! fail2ban_write_candidate "$candidate_file" "$ports_csv" "$backend"; then
        printf '无法生成 Fail2Ban 临时候选配置。\n' >&2
        rm -rf -- "$temporary_dir"
        return 30
    fi

    if fail2ban-client -c "$temporary_dir" -t; then
        printf 'Fail2Ban 临时合并配置预检通过；未修改系统配置或服务状态。\n'
    else
        printf 'Fail2Ban 临时合并配置预检失败；系统配置和服务状态未改变。\n' >&2
        result=30
    fi
    rm -rf -- "$temporary_dir"
    return "$result"
}

fail2ban_wait_ready() {
    local attempts=${VPS_FAIL2BAN_READY_ATTEMPTS:-10}
    local delay=${VPS_FAIL2BAN_READY_DELAY:-1}
    local attempt=1

    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=10
    [[ "$delay" =~ ^[0-9]+([.][0-9]+)?$ ]] || delay=1

    while (( attempt <= attempts )); do
        fail2ban-client ping >/dev/null 2>&1 && return 0
        (( attempt == attempts )) && break
        sleep "$delay"
        attempt=$((attempt + 1))
    done
    return 1
}

fail2ban_verify() {
    command -v fail2ban-client >/dev/null 2>&1 || return 50
    fail2ban_wait_ready || {
        printf 'Fail2Ban 服务在等待就绪后仍未响应。\n' >&2
        return 50
    }
    fail2ban-client status sshd >/dev/null 2>&1 || {
        printf 'Fail2Ban sshd jail 未运行。\n' >&2
        return 50
    }
    printf 'Fail2Ban 服务和 sshd jail 已通过验证。\n'
}

fail2ban_restore_dir() {
    local transaction_dir=$1
    local existed original_active original_enabled restore_failed=0

    [[ -r "$transaction_dir/config_existed" ]] || return 60
    [[ -r "$transaction_dir/service_active" ]] || return 60
    [[ -r "$transaction_dir/service_enabled" ]] || return 60
    IFS= read -r existed < "$transaction_dir/config_existed"
    IFS= read -r original_active < "$transaction_dir/service_active"
    IFS= read -r original_enabled < "$transaction_dir/service_enabled"

    if [[ "$existed" == yes ]]; then
        [[ -f "$transaction_dir/original.conf" ]] || return 60
        install -m 644 "$transaction_dir/original.conf" "$CONFIG_FILE" || return 60
    else
        rm -f "$CONFIG_FILE" || return 60
    fi

    if [[ "$original_enabled" == yes ]]; then
        systemctl enable fail2ban >/dev/null 2>&1 || restore_failed=1
    else
        systemctl disable fail2ban >/dev/null 2>&1 || restore_failed=1
    fi

    if [[ "$original_active" == yes ]]; then
        systemctl restart fail2ban >/dev/null 2>&1 || restore_failed=1
    else
        systemctl stop fail2ban >/dev/null 2>&1 || restore_failed=1
    fi
    (( restore_failed == 0 )) || return 60
    printf '已恢复应用前的 Fail2Ban 模块配置。\n'
}

fail2ban_apply() {
    local ports backend ports_csv transaction_dir config_dir
    local original_active=no original_enabled=no

    vps_require_root || return $?
    fail2ban_check || return $?
    ports=$(fail2ban_ports)
    backend=$(fail2ban_backend)
    ports_csv=$(printf '%s\n' "$ports" | paste -sd, -)

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update || return 40
        DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban || return 40
    fi

    transaction_dir=$(vps_new_transaction_dir "$MODULE_ID") || return 40
    systemctl is-active --quiet fail2ban && original_active=yes
    systemctl is-enabled --quiet fail2ban && original_enabled=yes
    printf '%s\n' "$original_active" > "$transaction_dir/service_active" || return 40
    printf '%s\n' "$original_enabled" > "$transaction_dir/service_enabled" || return 40
    config_dir=$(dirname -- "$CONFIG_FILE")
    install -d -m 755 "$config_dir" || return 40

    if [[ -f "$CONFIG_FILE" ]]; then
        printf 'yes\n' > "$transaction_dir/config_existed" || return 40
        cp "$CONFIG_FILE" "$transaction_dir/original.conf" || return 40
    else
        printf 'no\n' > "$transaction_dir/config_existed" || return 40
    fi

    fail2ban_write_candidate "$transaction_dir/candidate.conf" "$ports_csv" "$backend" || return 40
    install -m 644 "$transaction_dir/candidate.conf" "$CONFIG_FILE" || return 40

    if ! fail2ban-client -t; then
        fail2ban_restore_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 40
    fi

    if ! systemctl enable fail2ban || ! systemctl restart fail2ban; then
        fail2ban_restore_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 40
    fi

    if ! fail2ban_verify; then
        fail2ban_restore_dir "$transaction_dir" >/dev/null 2>&1 || true
        return 50
    fi

    vps_set_last_transaction "$MODULE_ID" "$transaction_dir" || return 40
    printf 'Fail2Ban 配置完成。事务记录: %s\n' "$transaction_dir"
}

fail2ban_status() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        printf 'Fail2Ban 未安装。\n'
        return 10
    fi
    fail2ban-client status sshd
}

fail2ban_rollback() {
    local transaction_dir
    vps_require_root || return $?
    transaction_dir=$(vps_last_transaction "$MODULE_ID") || {
        printf '没有可回滚的 Fail2Ban 事务。\n' >&2
        return 60
    }
    fail2ban_restore_dir "$transaction_dir"
}

case ${1:-} in
    check) fail2ban_check ;;
    plan) fail2ban_plan ;;
    preflight) fail2ban_preflight ;;
    apply) fail2ban_apply ;;
    verify) fail2ban_verify ;;
    status|doctor) fail2ban_status ;;
    rollback) fail2ban_rollback ;;
    backup)
        printf 'Fail2Ban 配置备份在 apply 操作中自动创建。\n'
        ;;
    *)
        printf 'security.fail2ban 不支持操作: %s\n' "${1:-}" >&2
        exit 64
        ;;
esac
