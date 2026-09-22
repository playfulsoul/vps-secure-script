#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"
# shellcheck source=../../../core/packages.sh
source "$VPS_PLATFORM_ROOT/core/packages.sh"
# shellcheck source=../../../core/ssh.sh
source "$VPS_PLATFORM_ROOT/core/ssh.sh"
# shellcheck source=../../../core/ssh_keys.sh
source "$VPS_PLATFORM_ROOT/core/ssh_keys.sh"

MODULE_ID=${VPS_MODULE_ID:-security.login-hardening}
LOGIN_PASSWD_FILE=${VPS_LOGIN_PASSWD_FILE:-/etc/passwd}
LOGIN_GROUP_FILE=${VPS_LOGIN_GROUP_FILE:-/etc/group}
LOGIN_SSHD_CONFIG_DIR=${VPS_LOGIN_SSHD_CONFIG_DIR:-/etc/ssh/sshd_config.d}
LOGIN_CONFIG_FILE=${VPS_LOGIN_CONFIG_FILE:-$LOGIN_SSHD_CONFIG_DIR/00-vps-secure-login-hardening.conf}
LOGIN_AUTH_LOG_FILE=${VPS_LOGIN_AUTH_LOG_FILE:-}
LOGIN_SSH_UNIT=${VPS_LOGIN_SSH_UNIT:-ssh.service}
LOGIN_VERIFY_TTL=${VPS_LOGIN_VERIFY_TTL:-1800}
LOGIN_RANDOM_FILE=${VPS_LOGIN_RANDOM_FILE:-/dev/urandom}
LOGIN_MARKER='# Managed by VPS Secure login hardening'

login_require_root() {
    if [[ ${VPS_LOGIN_ALLOW_NON_ROOT:-no} == yes ]]; then return 0; fi
    vps_require_root
}

login_hash_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{ print $1 }'
    else
        printf '%s' "$1" | shasum -a 256 | awk '{ print $1 }'
    fi
}

login_user_name_valid() {
    [[ ${1:-} =~ ^[a-z_][a-z0-9_-]{0,31}$ && ${1:-} != root ]]
}

login_user_record() {
    local username=$1
    if [[ "$LOGIN_PASSWD_FILE" == /etc/passwd ]] && command -v getent >/dev/null 2>&1; then
        getent passwd "$username"
    else
        awk -F: -v requested="$username" '
            $1 == requested { print; found=1; exit }
            END { if (!found) exit 1 }
        ' "$LOGIN_PASSWD_FILE"
    fi
}

login_user_home() {
    login_user_record "$1" | awk -F: '{ print $6 }'
}

login_user_ids() {
    login_user_record "$1" | awk -F: '{ print $3 ":" $4 }'
}

login_user_in_sudo() {
    local username=$1
    if [[ "$LOGIN_GROUP_FILE" == /etc/group ]] && command -v id >/dev/null 2>&1; then
        id -nG "$username" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo
    else
        awk -F: -v requested="$username" '
            $1 == "sudo" {
                count=split($4, users, ",")
                for (i=1; i<=count; i++) if (users[i] == requested) found=1
            }
            END { exit !found }
        ' "$LOGIN_GROUP_FILE"
    fi
}

login_require_tools() {
    local tool
    for tool in useradd usermod userdel gpasswd passwd ssh-keygen; do
        command -v "$tool" >/dev/null 2>&1 || {
            printf '缺少登录安全所需命令: %s\n' "$tool" >&2
            return 20
        }
    done
    vps_find_sshd >/dev/null 2>&1 || {
        printf '未找到 sshd。\n' >&2
        return 20
    }
}

login_file_identity() {
    stat -c '%d:%i' -- "$1" 2>/dev/null || stat -f '%d:%i' "$1"
}

login_file_size() {
    stat -c %s -- "$1" 2>/dev/null || stat -f %z "$1"
}

login_capture_auth_boundary() {
    local transaction=$1 path=''
    if [[ -n "$LOGIN_AUTH_LOG_FILE" ]]; then
        path=$LOGIN_AUTH_LOG_FILE
    elif [[ -e /var/log/auth.log ]]; then
        path=/var/log/auth.log
    fi
    if [[ -n "$path" ]]; then
        [[ "$path" == /* && "$path" != *$'\n'* ]] || return 1
        printf 'file\n' > "$transaction/auth-source" || return 1
        printf '%s\n' "$path" > "$transaction/auth-log-path" || return 1
        if [[ -f "$path" && ! -L "$path" ]]; then
            login_file_identity "$path" > "$transaction/auth-log-identity" || return 1
            login_file_size "$path" > "$transaction/auth-log-size" || return 1
        elif [[ ! -e "$path" ]]; then
            printf 'absent\n' > "$transaction/auth-log-identity" || return 1
            printf '0\n' > "$transaction/auth-log-size" || return 1
        else
            return 1
        fi
    else
        printf 'journal\n' > "$transaction/auth-source" || return 1
    fi
}

login_state_dir() {
    vps_module_state_dir "$MODULE_ID"
}

login_pointer_set() {
    local name=$1 transaction=$2 state temporary
    state=$(login_state_dir) || return 1
    case "$transaction" in "$state"/transactions/*) ;; *) return 1 ;; esac
    temporary="$state/.$name.$$"
    printf '%s\n' "$transaction" > "$temporary" || return 1
    mv -f -- "$temporary" "$state/$name"
}

login_pointer_get() {
    local name=$1 state transaction
    state=$(login_state_dir) || return 1
    [[ -r "$state/$name" ]] || return 1
    IFS= read -r transaction < "$state/$name" || return 1
    case "$transaction" in
        "$state"/transactions/*) [[ -d "$transaction" ]] || return 1 ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$transaction"
}

login_lock_acquire() {
    local state
    state=$(login_state_dir) || return 1
    mkdir -p "$state/transactions" || return 1
    chmod 700 "$(vps_state_root)" "$(vps_state_root)/modules" "$state" "$state/transactions" || return 1
    mkdir "$state/operation-lock" || {
        printf '登录安全操作锁存在，请先检查未完成事务。\n' >&2
        return 40
    }
}

login_lock_release() {
    rmdir "$(login_state_dir)/operation-lock" 2>/dev/null || true
}

login_issue_token() {
    local transaction=$1 token now
    token=$(od -An -N16 -tx1 "$LOGIN_RANDOM_FILE" 2>/dev/null | tr -d ' \n')
    [[ "$token" =~ ^[a-f0-9]{32}$ ]] || return 40
    now=$(date +%s)
    login_hash_text "$token" > "$transaction/token.sha256" || return 40
    printf '%s\n' "$now" > "$transaction/token-created" || return 40
    login_capture_auth_boundary "$transaction" || return 40
    printf 'awaiting-verification\n' > "$transaction/phase" || return 40
    rm -f -- "$transaction/verified-at" "$transaction/verified-session.sha256"
    printf '\n请保持当前窗口，使用新用户和密钥打开另一个 SSH 窗口，然后运行：\n'
    # shellcheck disable=SC2016
    printf 'sudo env VPS_LOGIN_SESSION="$SSH_CONNECTION" vps login verify --token %s\n' "$token"
    printf '验证完成前，密码登录和 root 登录不会被关闭。\n'
}

login_key_module() {
    if [[ -n ${VPS_LOGIN_KEY_MODULE_COMMAND:-} ]]; then
        "$VPS_LOGIN_KEY_MODULE_COMMAND" "$@"
    else
        VPS_MODULE_ID=security.ssh \
            "$VPS_PLATFORM_ROOT/modules/builtin/security-ssh/module.sh" "$@"
    fi
}

login_compensate_prepare() {
    local transaction=$1 username created added_sudo key_imported ssh_transaction current_ssh
    username=$(<"$transaction/username")
    created=$(<"$transaction/created-user")
    added_sudo=$(<"$transaction/added-sudo")
    key_imported=$(<"$transaction/key-imported")
    if [[ "$key_imported" == yes && -r "$transaction/ssh-transaction" ]]; then
        ssh_transaction=$(<"$transaction/ssh-transaction")
        current_ssh=$(vps_last_transaction security.ssh 2>/dev/null || true)
        if [[ "$current_ssh" == "$ssh_transaction" ]]; then login_key_module rollback || return 60; fi
    fi
    if [[ "$created" == yes ]]; then
        userdel -r "$username" >/dev/null 2>&1 || return 60
    elif [[ "$added_sudo" == yes ]]; then
        gpasswd -d "$username" sudo >/dev/null 2>&1 || return 60
    fi
    printf 'compensated\n' > "$transaction/phase"
}

login_plan() {
    local username='' github=''
    while (( $# > 0 )); do
        case $1 in
            --user) username=${2:-}; shift 2 ;;
            --github) github=${2:-}; shift 2 ;;
            *) printf '未知参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    login_user_name_valid "$username" || { printf '普通用户名格式无效，且不能是 root。\n' >&2; return 64; }
    vps_github_username_valid "$github" || { printf 'GitHub 用户名格式无效。\n' >&2; return 64; }
    printf '进阶登录安全准备计划：\n'
    if login_user_record "$username" >/dev/null 2>&1; then
        printf '  - 保留现有用户 %s，并确认其 sudo 权限。\n' "$username"
    else
        printf '  - 创建普通用户 %s、主目录和 Bash shell，并交互式设置密码。\n' "$username"
        printf '  - 将用户加入 sudo 组；创建失败时自动撤销本次新用户。\n'
    fi
    printf '  - 从 GitHub 用户 %s 导入公钥，保留已有授权内容。\n' "$github"
    printf '  - 生成一次性验证令牌；必须在新的公钥 SSH 会话中通过 sudo 验证。\n'
    printf '  - 本步骤不会修改 sshd 配置、SSH 端口、密码登录或 root 登录。\n'
}

login_prepare() (
    umask 077
    local username='' github='' state transaction created=no added_sudo=no key_imported=no ssh_transaction prepare_rc=0
    while (( $# > 0 )); do
        case $1 in
            --user) username=${2:-}; shift 2 ;;
            --github) github=${2:-}; shift 2 ;;
            *) return 64 ;;
        esac
    done
    login_require_root || return $?
    login_plan --user "$username" --github "$github" || return $?
    login_require_tools || return $?
    login_lock_acquire || return $?
    trap 'prepare_rc=$?; login_lock_release; exit "$prepare_rc"' EXIT
    state=$(login_state_dir) || return 40
    transaction=$(mktemp -d "$state/transactions/prepare.XXXXXX") || return 40
    chmod 700 "$transaction" || return 40
    printf '%s\n' "$username" > "$transaction/username"
    printf '%s\n' "$github" > "$transaction/github-user"
    printf '%s\n' "$created" > "$transaction/created-user"
    printf '%s\n' "$added_sudo" > "$transaction/added-sudo"
    printf '%s\n' "$key_imported" > "$transaction/key-imported"
    printf 'preparing\n' > "$transaction/phase"
    login_pointer_set verification_transaction "$transaction" || return 40

    if ! command -v sudo >/dev/null 2>&1; then
        if ! vps_apt_update || ! vps_apt_install sudo; then
            login_compensate_prepare "$transaction" || true
            return 40
        fi
    fi
    if ! login_user_record "$username" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$username" || return 40
        created=yes; printf '%s\n' "$created" > "$transaction/created-user"
        if ! passwd "$username"; then login_compensate_prepare "$transaction" || true; return 40; fi
    fi
    if ! login_user_in_sudo "$username"; then
        usermod -aG sudo "$username" || { login_compensate_prepare "$transaction" || true; return 40; }
        added_sudo=yes; printf '%s\n' "$added_sudo" > "$transaction/added-sudo"
    fi
    if ! login_key_module configure --github "$github" --user "$username"; then
        login_compensate_prepare "$transaction" || true
        return 40
    fi
    key_imported=yes; printf '%s\n' "$key_imported" > "$transaction/key-imported"
    ssh_transaction=$(vps_last_transaction security.ssh) || { login_compensate_prepare "$transaction" || true; return 40; }
    printf '%s\n' "$ssh_transaction" > "$transaction/ssh-transaction"
    printf '%s\n' "$(login_user_ids "$username")" > "$transaction/user-identity"
    login_issue_token "$transaction" || { login_compensate_prepare "$transaction" || true; return 40; }
)

login_auth_log_proves_publickey() {
    local username=$1 session=$2 transaction=$3 client_ip client_port server_ip server_port extra
    local needle source path recorded_identity current_identity recorded_size created temporary result
    read -r client_ip client_port server_ip server_port extra <<< "$session"
    [[ -n "$client_ip" && "$client_port" =~ ^[0-9]+$ && -n "$server_ip" && "$server_port" =~ ^[0-9]+$ && -z "${extra:-}" ]] || return 1
    needle="Accepted publickey for $username from $client_ip port $client_port "
    source=$(<"$transaction/auth-source") || return 1
    if [[ "$source" == file ]]; then
        path=$(<"$transaction/auth-log-path") || return 1
        recorded_identity=$(<"$transaction/auth-log-identity") || return 1
        recorded_size=$(<"$transaction/auth-log-size") || return 1
        [[ "$path" == /* && "$path" != *$'\n'* && "$recorded_size" =~ ^[0-9]+$ &&
           -f "$path" && ! -L "$path" ]] || return 1
        if [[ "$recorded_identity" != absent ]]; then
            current_identity=$(login_file_identity "$path") || return 1
            [[ "$current_identity" == "$recorded_identity" ]] || return 1
        fi
        tail -c "+$((recorded_size + 1))" -- "$path" 2>/dev/null | grep -Fq -- "$needle"
        return
    fi
    [[ "$source" == journal ]] || return 1
    created=$(<"$transaction/token-created") || return 1
    [[ "$created" =~ ^[0-9]+$ ]] || return 1
    command -v journalctl >/dev/null 2>&1 || return 1
    temporary=$(mktemp "${TMPDIR:-/tmp}/vps-login-auth.XXXXXX") || return 1
    journalctl --since "@$created" --no-pager -u ssh.service -u sshd.service > "$temporary" 2>/dev/null || true
    grep -Fq -- "$needle" "$temporary"
    local result=$?
    rm -f -- "$temporary"
    return "$result"
}

login_authorized_key_valid() {
    local username=$1 record uid gid home
    record=$(login_user_record "$username") || return 1
    uid=$(printf '%s\n' "$record" | awk -F: '{ print $3 }')
    gid=$(printf '%s\n' "$record" | awk -F: '{ print $4 }')
    home=$(printf '%s\n' "$record" | awk -F: '{ print $6 }')
    vps_ssh_paths_verify "$home" "$uid" "$gid"
}

login_verify() (
    umask 077
    local token='' session=${VPS_LOGIN_SESSION:-} transaction username stored created now sudo_user
    while (( $# > 0 )); do
        case $1 in
            --token) token=${2:-}; shift 2 ;;
            --session) session=${2:-}; shift 2 ;;
            *) return 64 ;;
        esac
    done
    login_require_root || return $?
    [[ "$token" =~ ^[a-f0-9]{32}$ ]] || { printf '验证令牌格式无效。\n' >&2; return 64; }
    transaction=$(login_pointer_get verification_transaction) || { printf '没有等待验证的登录安全事务。\n' >&2; return 60; }
    [[ "$(<"$transaction/phase")" == awaiting-verification ]] || { printf '当前事务不在等待验证阶段。\n' >&2; return 60; }
    username=$(<"$transaction/username")
    sudo_user=${SUDO_USER:-}
    [[ "$sudo_user" == "$username" ]] || { printf '必须由目标普通用户通过 sudo 执行验证。\n' >&2; return 60; }
    stored=$(<"$transaction/token.sha256")
    [[ "$(login_hash_text "$token")" == "$stored" ]] || { printf '一次性验证令牌不匹配。\n' >&2; return 60; }
    created=$(<"$transaction/token-created")
    now=$(date +%s)
    [[ "$created" =~ ^[0-9]+$ && "$LOGIN_VERIFY_TTL" =~ ^[0-9]+$ && $((now - created)) -le "$LOGIN_VERIFY_TTL" ]] || {
        printf '一次性验证令牌已过期，请从原窗口重新生成。\n' >&2
        return 60
    }
    login_user_in_sudo "$username" || { printf '目标用户当前不具备 sudo 组权限。\n' >&2; return 60; }
    login_authorized_key_valid "$username" || return 60
    login_auth_log_proves_publickey "$username" "$session" "$transaction" || {
        printf '未找到与当前连接匹配的公钥登录记录；不会解锁高风险设置。\n' >&2
        return 60
    }
    printf '%s\n' "$now" > "$transaction/verified-at"
    login_hash_text "$session" > "$transaction/verified-session.sha256"
    printf 'verified\n' > "$transaction/phase"
    rm -f -- "$transaction/token.sha256"
    printf '新窗口公钥登录与 sudo 已验证。现在可以返回原窗口继续下一步。\n'
)

login_verified_transaction() {
    local transaction username verified now
    transaction=$(login_pointer_get verification_transaction) || return 1
    [[ "$(<"$transaction/phase")" == verified ]] || return 1
    username=$(<"$transaction/username")
    [[ -z ${1:-} || "$username" == "$1" ]] || return 1
    verified=$(<"$transaction/verified-at")
    now=$(date +%s)
    [[ "$verified" =~ ^[0-9]+$ && $((now - verified)) -le "$LOGIN_VERIFY_TTL" ]] || return 1
    login_user_in_sudo "$username" || return 1
    login_authorized_key_valid "$username" || return 1
    printf '%s\n' "$transaction"
}

login_sshd_command() {
    printf '%s\n' "${VPS_LOGIN_SSHD_COMMAND:-$(vps_find_sshd)}"
}

login_sshd_validate() {
    "$(login_sshd_command)" -t
}

login_sshd_effective() {
    "$(login_sshd_command)" -T
}

login_effective_value() {
    login_sshd_effective 2>/dev/null | awk -v requested="$1" '$1 == requested { print $2; exit }'
}

login_root_mode_matches() {
    local expected=$1 actual=$2
    if [[ "$expected" == prohibit-password ]]; then
        [[ "$actual" == prohibit-password || "$actual" == without-password ]]
    else
        [[ "$actual" == "$expected" ]]
    fi
}

login_reload_ssh() {
    if [[ -n ${VPS_LOGIN_SYSTEMCTL_COMMAND:-} ]]; then
        "$VPS_LOGIN_SYSTEMCTL_COMMAND" reload "$LOGIN_SSH_UNIT"
        "$VPS_LOGIN_SYSTEMCTL_COMMAND" is-active --quiet "$LOGIN_SSH_UNIT"
    else
        systemctl reload "$LOGIN_SSH_UNIT" && systemctl is-active --quiet "$LOGIN_SSH_UNIT"
    fi
}

login_config_is_owned() {
    [[ ! -e "$LOGIN_CONFIG_FILE" ]] || { [[ -f "$LOGIN_CONFIG_FILE" && ! -L "$LOGIN_CONFIG_FILE" ]] && IFS= read -r marker < "$LOGIN_CONFIG_FILE" && [[ "$marker" == "$LOGIN_MARKER" ]]; }
}

login_config_value() {
    [[ -r "$LOGIN_CONFIG_FILE" ]] || return 1
    awk -v requested="$1" 'tolower($1) == tolower(requested) { print $2; exit }' "$LOGIN_CONFIG_FILE"
}

login_write_config() {
    local password=$1 root_mode=$2 output=$3
    printf '%s\n' "$LOGIN_MARKER" > "$output" || return 1
    if [[ "$password" == no ]]; then
        printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >> "$output" || return 1
    fi
    [[ -z "$root_mode" ]] || printf 'PermitRootLogin %s\n' "$root_mode" >> "$output" || return 1
}

login_record_effective_config() {
    local transaction=$1 name value
    for name in passwordauthentication kbdinteractiveauthentication permitrootlogin; do
        value=$(login_effective_value "$name") || return 1
        [[ -n "$value" ]] || return 1
        printf '%s\n' "$value" > "$transaction/effective-before-$name" || return 1
    done
}

login_restore_config() {
    local transaction=$1 existed name expected
    existed=$(<"$transaction/config-existed")
    if [[ "$existed" == yes ]]; then
        install -m 600 "$transaction/config-before" "$LOGIN_CONFIG_FILE" || return 1
    else
        rm -f -- "$LOGIN_CONFIG_FILE" || return 1
    fi
    login_sshd_validate && login_reload_ssh || return 1
    for name in passwordauthentication kbdinteractiveauthentication permitrootlogin; do
        [[ -r "$transaction/effective-before-$name" ]] || return 1
        expected=$(<"$transaction/effective-before-$name")
        [[ -n "$expected" && "$(login_effective_value "$name")" == "$expected" ]] || return 1
    done
}

login_restore_previous_transaction() {
    local previous=$1
    if [[ -n "$previous" ]]; then
        vps_set_last_transaction "$MODULE_ID" "$previous"
    else
        rm -f -- "$(login_state_dir)/last_transaction"
    fi
}

login_configure() (
    umask 077
    local operation=${1:-} username='' mode='' verification state transaction previous='' existed=no configure_rc=0
    local password='' root_mode='' temporary expected_password='' expected_root=''
    shift || true
    while (( $# > 0 )); do
        case $1 in
            --user) username=${2:-}; shift 2 ;;
            --mode) mode=${2:-}; shift 2 ;;
            *) return 64 ;;
        esac
    done
    login_require_root || return $?
    login_user_name_valid "$username" || return 64
    verification=$(login_verified_transaction "$username") || {
        printf '尚未完成有效的新窗口公钥登录与 sudo 验证；拒绝修改 sshd。\n' >&2
        return 60
    }
    login_config_is_owned || { printf '目标 SSH 配置文件不是本模块所有，拒绝覆盖。\n' >&2; return 60; }
    [[ -d "$LOGIN_SSHD_CONFIG_DIR" && ! -L "$LOGIN_SSHD_CONFIG_DIR" ]] || return 60
    password=$(login_config_value PasswordAuthentication 2>/dev/null || true)
    root_mode=$(login_config_value PermitRootLogin 2>/dev/null || true)
    case "$operation" in
        password-disable)
            password=no; expected_password=no
            ;;
        root-restrict)
            [[ "$(login_effective_value passwordauthentication)" == no && \
               "$(login_effective_value kbdinteractiveauthentication)" == no ]] || {
                printf '密码登录尚未有效关闭；必须先完成并重新验证该步骤。\n' >&2
                return 60
            }
            case "$mode" in
                key-only) root_mode=prohibit-password; expected_root=prohibit-password ;;
                disable) root_mode=no; expected_root=no ;;
                *) printf 'root 模式必须是 key-only 或 disable。\n' >&2; return 64 ;;
            esac
            ;;
        *) return 64 ;;
    esac
    login_lock_acquire || return $?
    trap 'configure_rc=$?; login_lock_release; exit "$configure_rc"' EXIT
    state=$(login_state_dir) || return 40
    previous=$(vps_last_transaction "$MODULE_ID" 2>/dev/null || true)
    transaction=$(mktemp -d "$state/transactions/config.XXXXXX") || return 40
    chmod 700 "$transaction" || return 40
    [[ ! -e "$LOGIN_CONFIG_FILE" ]] || { cp -p "$LOGIN_CONFIG_FILE" "$transaction/config-before" || return 40; existed=yes; }
    printf '%s\n' "$existed" > "$transaction/config-existed"
    printf '%s\n' "$username" > "$transaction/username"
    printf '%s\n' "$operation" > "$transaction/operation"
    printf '%s\n' "$previous" > "$transaction/previous-transaction"
    printf '%s\n' "$verification" > "$transaction/verification-transaction"
    login_record_effective_config "$transaction" || return 40
    printf 'prepared\n' > "$transaction/phase"
    vps_set_last_transaction "$MODULE_ID" "$transaction" || return 40
    temporary=$(mktemp "$LOGIN_SSHD_CONFIG_DIR/.vps-login.XXXXXX") || return 40
    login_write_config "$password" "$root_mode" "$temporary" || { rm -f -- "$temporary"; return 40; }
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 40; }
    mv -f -- "$temporary" "$LOGIN_CONFIG_FILE" || return 40
    if ! login_sshd_validate || ! login_reload_ssh ||
       { [[ -n "$expected_password" ]] && [[ "$(login_effective_value passwordauthentication)" != "$expected_password" ]]; } ||
       { [[ -n "$expected_password" ]] && [[ "$(login_effective_value kbdinteractiveauthentication)" != no ]]; } ||
       { [[ -n "$expected_root" ]] &&
         ! login_root_mode_matches "$expected_root" "$(login_effective_value permitrootlogin)"; }; then
        if login_restore_config "$transaction" &&
           printf 'compensated\n' > "$transaction/phase" &&
           login_restore_previous_transaction "$previous"; then
            :
        else
            printf 'recovery-failed\n' > "$transaction/phase" || true
            return 60
        fi
        printf '新 SSH 策略验证失败，已恢复原配置。\n' >&2
        return 50
    fi
    printf 'committed\n' > "$transaction/phase"
    if [[ "$operation" == password-disable ]]; then
        printf '密码与键盘交互登录已关闭；SSH 端口保持不变。\n'
        if ! login_issue_token "$verification"; then
            if login_restore_config "$transaction" &&
               printf 'compensated\n' > "$transaction/phase" &&
               login_restore_previous_transaction "$previous"; then
                printf '无法创建第二阶段验证令牌，已恢复关闭密码前的配置。\n' >&2
                return 50
            fi
            printf 'recovery-failed\n' > "$transaction/phase" || true
            printf '无法创建第二阶段验证令牌，且自动恢复未完成。\n' >&2
            return 60
        fi
        printf '必须再次从新窗口验证后，才会开放 root 登录限制。\n'
    else
        printf 'root 登录策略已设置为 %s；普通 sudo 用户保持可用。\n' "$root_mode"
    fi
)

login_preflight() {
    local username=${1:-} verification
    login_user_name_valid "$username" || return 64
    verification=$(login_verified_transaction "$username") || {
        printf '缺少有效的新窗口验证。\n' >&2
        return 60
    }
    login_sshd_validate || return 50
    printf '登录安全预检通过：用户、公钥、sudo、验证令牌和当前 sshd 配置均有效。\n'
    printf '验证事务：%s\n' "$verification"
}

login_status() {
    local username=${1:-} password root_mode transaction phase='未准备'
    password=$(login_effective_value passwordauthentication 2>/dev/null || printf 'unknown')
    root_mode=$(login_effective_value permitrootlogin 2>/dev/null || printf 'unknown')
    if transaction=$(login_pointer_get verification_transaction 2>/dev/null); then phase=$(<"$transaction/phase"); fi
    printf '密码登录: %s\n' "$password"
    printf 'root 登录策略: %s\n' "$root_mode"
    printf '新窗口验证状态: %s\n' "$phase"
    if [[ -n "$username" ]]; then
        if login_user_record "$username" >/dev/null 2>&1; then printf '普通用户 %s: 已存在\n' "$username"; else printf '普通用户 %s: 不存在\n' "$username"; fi
        if login_user_in_sudo "$username"; then printf 'sudo 权限: 已加入 sudo 组\n'; else printf 'sudo 权限: 未确认\n'; fi
    fi
}

login_rollback() (
    umask 077
    local transaction phase previous username rollback_rc=0
    login_require_root || return $?
    transaction=$(vps_last_transaction "$MODULE_ID") || { printf '没有可回滚的登录策略事务。\n' >&2; return 60; }
    phase=$(<"$transaction/phase")
    [[ "$phase" == committed ]] || { printf '最近事务不是可回滚的已提交配置。\n' >&2; return 60; }
    login_lock_acquire || return $?
    trap 'rollback_rc=$?; login_lock_release; exit "$rollback_rc"' EXIT
    login_restore_config "$transaction" || { printf 'recovery-failed\n' > "$transaction/phase"; return 60; }
    printf 'rolled-back\n' > "$transaction/phase"
    previous=$(<"$transaction/previous-transaction")
    if [[ -n "$previous" ]]; then
        vps_set_last_transaction "$MODULE_ID" "$previous" || return 60
    else
        rm -f -- "$(login_state_dir)/last_transaction"
    fi
    username=$(<"$transaction/username")
    transaction=$(login_pointer_get verification_transaction) || return 60
    login_issue_token "$transaction" || return 60
    printf '已恢复上一次 SSH 登录策略；再次强化前需要重新验证新窗口。\n'
)

case ${1:-} in
    check) login_require_tools ;;
    status|doctor) shift; login_status "$@" ;;
    plan) shift; login_plan "$@" ;;
    preflight) shift; login_preflight "$@" ;;
    apply) shift; login_prepare "$@" ;;
    verify) shift; login_verify "$@" ;;
    configure) shift; login_configure "$@" ;;
    rollback) login_rollback ;;
    *) printf 'security.login-hardening 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
