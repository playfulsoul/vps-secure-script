#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/packages.sh
source "$VPS_PLATFORM_ROOT/core/packages.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

user_name_valid() {
    [[ ${1:-} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

users_check() {
    command -v useradd >/dev/null 2>&1 && command -v usermod >/dev/null 2>&1 || return 20
}

users_status() {
    awk -F: '($3 >= 1000 && $1 != "nobody") { printf "%-24s UID=%s HOME=%s SHELL=%s\n", $1, $3, $6, $7 }' /etc/passwd
}

users_plan() {
    local operation=${1:-} username=${2:-}
    case "$operation" in
        add)
            user_name_valid "$username" || { printf '用户名无效。\n' >&2; return 64; }
            printf '将创建用户 %s、主目录和 Bash shell，并加入 sudo 组。\n' "$username"
            printf '创建后将交互式设置密码。\n'
            ;;
        remove)
            user_name_valid "$username" || { printf '用户名无效。\n' >&2; return 64; }
            [[ "$username" != root ]] || return 64
            printf '将删除用户 %s。仅在额外指定 --delete-home 时删除主目录。\n' "$username"
            ;;
        *)
            printf '用法: plan <add|remove> <用户名> [--delete-home]\n' >&2
            return 64
            ;;
    esac
}

users_configure() {
    local operation=${1:-} username=${2:-} delete_home=${3:-}
    vps_require_root || return $?
    users_check || return $?
    users_plan "$operation" "$username" "$delete_home" || return $?

    case "$operation" in
        add)
            id "$username" >/dev/null 2>&1 && { printf '用户已存在。\n'; return 10; }
            command -v sudo >/dev/null 2>&1 || {
                vps_apt_update || return 40
                vps_apt_install sudo || return 40
            }
            useradd -m -s /bin/bash "$username" || return 40
            if ! passwd "$username"; then
                userdel -r "$username" 2>/dev/null || true
                return 40
            fi
            if ! usermod -aG sudo "$username"; then
                userdel -r "$username" 2>/dev/null || true
                return 40
            fi
            printf '用户 %s 已创建并加入 sudo 组。\n' "$username"
            ;;
        remove)
            id "$username" >/dev/null 2>&1 || { printf '用户不存在。\n'; return 10; }
            if [[ "$delete_home" == --delete-home ]]; then
                userdel -r "$username" || return 40
            else
                userdel "$username" || return 40
            fi
            printf '用户 %s 已删除。\n' "$username"
            ;;
    esac
}

case ${1:-} in
    check) users_check ;;
    status|doctor) users_status ;;
    plan) shift; users_plan "$@" ;;
    configure) shift; users_configure "$@" ;;
    *) printf 'system.users 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
