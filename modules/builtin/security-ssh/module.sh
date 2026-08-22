#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/ssh.sh
source "$VPS_PLATFORM_ROOT/core/ssh.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"
# shellcheck source=../../../core/ssh_keys.sh
source "$VPS_PLATFORM_ROOT/core/ssh_keys.sh"

MODULE_ID=${VPS_MODULE_ID:-security.ssh}

ssh_key_passwd_record() {
    local username=$1 passwd_file=${VPS_PASSWD_FILE:-/etc/passwd}
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$username"
    else
        awk -F: -v requested="$username" '$1 == requested { print; exit }' "$passwd_file"
    fi
}

ssh_check() {
    if ! vps_find_sshd >/dev/null 2>&1; then
        printf '[FAIL] 未找到 sshd。\n' >&2
        return 20
    fi
}

ssh_status() {
    local current_port ports

    ssh_check || return $?

    current_port=$(vps_ssh_connection_port "${SSH_CONNECTION:-}" 2>/dev/null || true)
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

ssh_key_parse_args() {
    SSH_KEY_GITHUB_USER=''
    SSH_KEY_TARGET_USER=root
    while (( $# > 0 )); do
        case $1 in
            --github) SSH_KEY_GITHUB_USER=${2:-}; shift 2 ;;
            --user) SSH_KEY_TARGET_USER=${2:-}; shift 2 ;;
            *) printf '未知公钥参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    vps_github_username_valid "$SSH_KEY_GITHUB_USER" || {
        printf 'GitHub 用户名格式无效。\n' >&2
        return 64
    }
    [[ "$SSH_KEY_TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
        printf '服务器用户名格式无效。\n' >&2
        return 64
    }
    ssh_key_passwd_record "$SSH_KEY_TARGET_USER" >/dev/null 2>&1 || {
        printf '服务器用户不存在: %s\n' "$SSH_KEY_TARGET_USER" >&2
        return 20
    }
}

ssh_key_user_fields() {
    local record
    record=$(ssh_key_passwd_record "$SSH_KEY_TARGET_USER") || return 1
    SSH_KEY_UID=$(printf '%s\n' "$record" | awk -F: '{ print $3 }')
    SSH_KEY_GID=$(printf '%s\n' "$record" | awk -F: '{ print $4 }')
    SSH_KEY_HOME=${VPS_SSH_KEY_HOME:-$(printf '%s\n' "$record" | awk -F: '{ print $6 }')}
    [[ "$SSH_KEY_UID" =~ ^[0-9]+$ && "$SSH_KEY_GID" =~ ^[0-9]+$ && "$SSH_KEY_HOME" == /* ]]
}

ssh_key_secure_home() {
    vps_ssh_secure_home "$SSH_KEY_HOME" "$SSH_KEY_UID" "$SSH_KEY_GID"
}

ssh_key_paths_verify() {
    vps_ssh_paths_verify "$SSH_KEY_HOME" "$SSH_KEY_UID" "$SSH_KEY_GID"
}

ssh_key_plan() {
    ssh_key_parse_args "$@" || return $?
    ssh_key_user_fields || return 20
    printf 'SSH 公钥导入计划：\n'
    printf '  - 从 https://github.com/%s.keys 获取公开 SSH 密钥。\n' "$SSH_KEY_GITHUB_USER"
    printf '  - 验证密钥格式并显示指纹。\n'
    printf '  - 检查并修复目标用户主目录的所有者和可写权限。\n'
    printf '  - 去重后写入服务器用户 %s 的 %s/.ssh/authorized_keys。\n' \
        "$SSH_KEY_TARGET_USER" "$SSH_KEY_HOME"
    printf '  - 保留已有公钥，并创建可回滚备份。\n'
    printf '  - 不修改 SSH 端口，也不会自动关闭密码登录。\n'
}

ssh_key_download() {
    local output_file=$1
    command -v curl >/dev/null 2>&1 || { printf '导入 GitHub 公钥需要 curl。\n' >&2; return 20; }
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --connect-timeout 5 --max-time 20 --max-filesize 1048576 \
        "https://github.com/$SSH_KEY_GITHUB_USER.keys" -o "$output_file" || {
        printf '无法获取 GitHub 公钥，请检查用户名和网络。\n' >&2
        return 30
    }
    vps_validate_public_key_file "$output_file" || {
        printf 'GitHub 返回内容不包含可接受的 SSH 公钥。\n' >&2
        return 30
    }
}

ssh_key_show_fingerprints() {
    local key_file=$1 line temporary_key
    command -v ssh-keygen >/dev/null 2>&1 || return 20
    temporary_key=$(mktemp "${TMPDIR:-/tmp}/vps-secure-key.XXXXXX") || return 40
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        printf '%s\n' "$line" > "$temporary_key"
        ssh-keygen -lf "$temporary_key" || { rm -f "$temporary_key"; return 30; }
    done < "$key_file"
    rm -f "$temporary_key"
}

ssh_key_configure() {
    local temporary_dir imported_file ssh_dir authorized_keys merged transaction_dir existed=no
    vps_require_root || return $?
    ssh_key_parse_args "$@" || return $?
    ssh_key_user_fields || return 20
    ssh_dir="$SSH_KEY_HOME/.ssh"
    authorized_keys="$ssh_dir/authorized_keys"
    [[ ! -L "$ssh_dir" && ! -L "$authorized_keys" ]] || {
        printf '拒绝写入符号链接形式的 SSH 授权路径。\n' >&2
        return 40
    }

    temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-secure-ssh-key.XXXXXX") || return 40
    imported_file="$temporary_dir/imported.keys"
    merged="$temporary_dir/authorized_keys"
    if ! ssh_key_download "$imported_file"; then rm -rf -- "$temporary_dir"; return 30; fi
    printf '即将导入以下密钥指纹：\n'
    if ! ssh_key_show_fingerprints "$imported_file"; then rm -rf -- "$temporary_dir"; return 30; fi
    if ! ssh_key_secure_home; then rm -rf -- "$temporary_dir"; return 40; fi

    transaction_dir=$(vps_new_transaction_dir "$MODULE_ID") || { rm -rf -- "$temporary_dir"; return 40; }
    printf '%s\n' "$SSH_KEY_TARGET_USER" > "$transaction_dir/target_user"
    printf '%s\n' "$authorized_keys" > "$transaction_dir/authorized_keys_path"
    if [[ -f "$authorized_keys" ]]; then
        existed=yes
        cp -p "$authorized_keys" "$transaction_dir/original_authorized_keys" || return 40
        vps_merge_authorized_keys "$authorized_keys" "$imported_file" "$merged" || return 40
    else
        : > "$temporary_dir/empty"
        vps_merge_authorized_keys "$temporary_dir/empty" "$imported_file" "$merged" || return 40
    fi
    printf '%s\n' "$existed" > "$transaction_dir/authorized_keys_existed"
    install -d -m 700 -o "$SSH_KEY_UID" -g "$SSH_KEY_GID" "$ssh_dir" || return 40
    install -m 600 -o "$SSH_KEY_UID" -g "$SSH_KEY_GID" "$merged" "$authorized_keys" || return 40
    cp "$imported_file" "$transaction_dir/imported.keys" || return 40
    vps_set_last_transaction "$MODULE_ID" "$transaction_dir" || return 40
    rm -rf -- "$temporary_dir"
    printf '公钥已导入用户 %s。请保持当前窗口，并立即新开窗口测试密钥登录。\n' "$SSH_KEY_TARGET_USER"
    printf '确认密钥登录成功前，不要关闭密码登录。\n'
}

ssh_key_verify() {
    local transaction_dir authorized_keys imported_file key target_user
    transaction_dir=$(vps_last_transaction "$MODULE_ID") || {
        printf '没有可验证的 SSH 公钥导入记录。\n' >&2
        return 60
    }
    IFS= read -r target_user < "$transaction_dir/target_user"
    SSH_KEY_TARGET_USER=$target_user
    ssh_key_user_fields || return 50
    IFS= read -r authorized_keys < "$transaction_dir/authorized_keys_path"
    imported_file="$transaction_dir/imported.keys"
    [[ -f "$authorized_keys" && -f "$imported_file" ]] || return 50
    ssh_key_paths_verify || return $?
    while IFS= read -r key || [[ -n "$key" ]]; do
        grep -Fxq -- "$key" "$authorized_keys" || {
            printf '授权文件中缺少已导入的公钥。\n' >&2
            return 50
        }
    done < "$imported_file"
    printf '已导入的公钥仍存在于授权文件中。\n'
}

ssh_key_rollback() {
    local transaction_dir authorized_keys existed target_user record uid gid
    vps_require_root || return $?
    transaction_dir=$(vps_last_transaction "$MODULE_ID") || {
        printf '没有可回滚的 SSH 公钥导入记录。\n' >&2
        return 60
    }
    IFS= read -r authorized_keys < "$transaction_dir/authorized_keys_path"
    IFS= read -r existed < "$transaction_dir/authorized_keys_existed"
    IFS= read -r target_user < "$transaction_dir/target_user"
    record=$(ssh_key_passwd_record "$target_user") || return 60
    uid=$(printf '%s\n' "$record" | awk -F: '{ print $3 }')
    gid=$(printf '%s\n' "$record" | awk -F: '{ print $4 }')
    if [[ "$existed" == yes ]]; then
        install -m 600 -o "$uid" -g "$gid" "$transaction_dir/original_authorized_keys" "$authorized_keys" || return 60
    else
        rm -f "$authorized_keys" || return 60
    fi
    printf '已恢复导入公钥之前的 authorized_keys。\n'
}

case ${1:-} in
    check)
        ssh_check
        ;;
    status|doctor)
        ssh_status
        ;;
    plan) shift; ssh_key_plan "$@" ;;
    configure) shift; ssh_key_configure "$@" ;;
    verify) ssh_key_verify ;;
    rollback) ssh_key_rollback ;;
    *)
        printf 'security.ssh 不支持操作: %s\n' "${1:-}" >&2
        exit 64
        ;;
esac
