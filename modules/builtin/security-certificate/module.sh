#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/platform.sh
source "$VPS_PLATFORM_ROOT/core/platform.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

MODULE_ID=${VPS_MODULE_ID:-security.certificate}
CONFIG_FILE=${VPS_CERT_CONFIG_FILE:-/etc/vps-secure/certificate-lifecycle.conf}
CRON_TAG='# vps-secure:security.certificate'

certificate_reset_config() {
    CERT_DEPLOY_BASE=${VPS_CERT_DEPLOY_BASE:-/etc/vps-secure/certificates}
    CERT_DOMAIN=${VPS_CERT_DOMAIN:-}
    CERT_ACME_CLIENT=${VPS_CERT_ACME_CLIENT:-}
    CERT_ACME_DOMAIN_CONF=${VPS_CERT_ACME_DOMAIN_CONF:-}
    CERT_ACME_CERT_FILE=${VPS_CERT_ACME_CERT_FILE:-}
    CERT_ACME_KEY_FILE=${VPS_CERT_ACME_KEY_FILE:-}
    CERT_ACME_ECC=${VPS_CERT_ACME_ECC:-no}
    CERT_DEPLOY_ROOT=${VPS_CERT_DEPLOY_ROOT:-}
    CERT_SERVICE_UNIT=${VPS_CERT_SERVICE_UNIT:-}
    CERT_SERVICE_ACTION=${VPS_CERT_SERVICE_ACTION:-reload}
    CERT_CRON_KIND=${VPS_CERT_CRON_KIND:-system}
    CERT_CRON_FILE=${VPS_CERT_CRON_FILE:-/etc/cron.d/vps-secure-certificate}
    CERT_CRON_USER=${VPS_CERT_CRON_USER:-root}
    CERT_VPS_COMMAND=${VPS_CERT_VPS_COMMAND:-/usr/local/bin/vps}
    CERT_MIN_VALIDITY_SECONDS=${VPS_CERT_MIN_VALIDITY_SECONDS:-604800}
    CERT_LOCAL_PORT=${VPS_CERT_LOCAL_PORT:-}
    CERT_DIRECT_HOST=${VPS_CERT_DIRECT_HOST:-}
    CERT_DIRECT_PORT=${VPS_CERT_DIRECT_PORT:-}
    CERT_FORWARD_HOST=${VPS_CERT_FORWARD_HOST:-}
    CERT_FORWARD_PORT=${VPS_CERT_FORWARD_PORT:-}
    CERT_PANEL_HEALTHCHECK=${VPS_CERT_PANEL_HEALTHCHECK:-}
    CERT_REALITY_HEALTHCHECK=${VPS_CERT_REALITY_HEALTHCHECK:-}
    CERT_VLESS_HEALTHCHECK=${VPS_CERT_VLESS_HEALTHCHECK:-}
}

certificate_config_assign() {
    local key=$1 value=$2
    case "$key" in
        domain) [[ -n "$CERT_DOMAIN" ]] || CERT_DOMAIN=$value ;;
        acme_client) [[ -n "$CERT_ACME_CLIENT" ]] || CERT_ACME_CLIENT=$value ;;
        acme_domain_conf) [[ -n "$CERT_ACME_DOMAIN_CONF" ]] || CERT_ACME_DOMAIN_CONF=$value ;;
        acme_cert_file) [[ -n "$CERT_ACME_CERT_FILE" ]] || CERT_ACME_CERT_FILE=$value ;;
        acme_key_file) [[ -n "$CERT_ACME_KEY_FILE" ]] || CERT_ACME_KEY_FILE=$value ;;
        acme_ecc) [[ -n ${VPS_CERT_ACME_ECC:-} ]] || CERT_ACME_ECC=$value ;;
        deploy_root) [[ -n "$CERT_DEPLOY_ROOT" ]] || CERT_DEPLOY_ROOT=$value ;;
        service_unit) [[ -n "$CERT_SERVICE_UNIT" ]] || CERT_SERVICE_UNIT=$value ;;
        service_action) [[ -n ${VPS_CERT_SERVICE_ACTION:-} ]] || CERT_SERVICE_ACTION=$value ;;
        cron_kind) [[ -n ${VPS_CERT_CRON_KIND:-} ]] || CERT_CRON_KIND=$value ;;
        cron_file) [[ -n ${VPS_CERT_CRON_FILE:-} ]] || CERT_CRON_FILE=$value ;;
        cron_user) [[ -n ${VPS_CERT_CRON_USER:-} ]] || CERT_CRON_USER=$value ;;
        vps_command) [[ -n ${VPS_CERT_VPS_COMMAND:-} ]] || CERT_VPS_COMMAND=$value ;;
        min_validity_seconds) [[ -n ${VPS_CERT_MIN_VALIDITY_SECONDS:-} ]] || CERT_MIN_VALIDITY_SECONDS=$value ;;
        local_port) [[ -n "$CERT_LOCAL_PORT" ]] || CERT_LOCAL_PORT=$value ;;
        direct_host) [[ -n "$CERT_DIRECT_HOST" ]] || CERT_DIRECT_HOST=$value ;;
        direct_port) [[ -n "$CERT_DIRECT_PORT" ]] || CERT_DIRECT_PORT=$value ;;
        forward_host) [[ -n "$CERT_FORWARD_HOST" ]] || CERT_FORWARD_HOST=$value ;;
        forward_port) [[ -n "$CERT_FORWARD_PORT" ]] || CERT_FORWARD_PORT=$value ;;
        panel_healthcheck) [[ -n "$CERT_PANEL_HEALTHCHECK" ]] || CERT_PANEL_HEALTHCHECK=$value ;;
        reality_healthcheck) [[ -n "$CERT_REALITY_HEALTHCHECK" ]] || CERT_REALITY_HEALTHCHECK=$value ;;
        vless_healthcheck) [[ -n "$CERT_VLESS_HEALTHCHECK" ]] || CERT_VLESS_HEALTHCHECK=$value ;;
        *)
            printf '证书生命周期配置包含未知字段: %s\n' "$key" >&2
            return 30
            ;;
    esac
}

certificate_load_config() {
    local line key value
    certificate_reset_config
    if [[ -r "$CONFIG_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line=${line%$'\r'}
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ ! "$line" =~ ^[a-z_]+=[^[:cntrl:]]*$ ]]; then
                printf '证书生命周期配置包含无效行；未显示原始内容。\n' >&2
                return 30
            fi
            key=${line%%=*}
            value=${line#*=}
            certificate_config_assign "$key" "$value" || return $?
        done < "$CONFIG_FILE"
    fi
}

certificate_supported_platform() {
    local platform
    platform=$(vps_platform_id 2>/dev/null || true)
    case "$platform" in
        debian|ubuntu) return 0 ;;
        *)
            printf '证书生命周期模块暂不支持此平台。\n' >&2
            return 20
            ;;
    esac
}

certificate_path_is_absolute() {
    [[ ${1:-} == /* && ${1:-} != *$'\n'* ]]
}

certificate_command_path_syntax_safe() {
    [[ ${1:-} =~ ^/[A-Za-z0-9._/+:-]+$ ]]
}

certificate_stat_uid() {
    stat -Lc %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null
}

certificate_stat_mode() {
    stat -Lc %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

certificate_owned_path_safe() {
    local path=$1 expected_uid=$2 uid mode
    uid=$(certificate_stat_uid "$path") || return 1
    mode=$(certificate_stat_mode "$path") || return 1
    [[ "$uid" == "$expected_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

certificate_owned_chain_safe() {
    local path=$1 stop=$2 expected_uid=$3
    while :; do
        certificate_owned_path_safe "$path" "$expected_uid" || return 1
        [[ "$path" == "$stop" ]] && return 0
        if [[ "$stop" == / ]]; then
            [[ "$path" == /* ]] || return 1
        else
            [[ "$path" == "$stop"/* ]] || return 1
        fi
        path=${path%/*}
        [[ -n "$path" ]] || path=/
    done
}

certificate_root_executable_safe() {
    local command_path=$1 trust_root expected_uid resolved command_parent
    certificate_command_path_syntax_safe "$command_path" || return 1
    trust_root=${VPS_CERT_COMMAND_TRUST_ROOT:-/}
    trust_root=$(readlink -f -- "$trust_root" 2>/dev/null) || return 1
    resolved=$(readlink -f -- "$command_path" 2>/dev/null) || return 1
    [[ -f "$resolved" && -x "$resolved" ]] || return 1
    if [[ ${VPS_CERT_ALLOW_UNSAFE_TEST_HOOKS:-no} == yes ]]; then
        expected_uid=$(id -u)
    else
        expected_uid=0
    fi
    [[ "$resolved" == "$trust_root"/* ]] || [[ "$trust_root" == / && "$resolved" == /* ]] || return 1
    certificate_owned_chain_safe "$resolved" "$trust_root" "$expected_uid" || return 1
    command_parent=$(readlink -f -- "${command_path%/*}" 2>/dev/null) || return 1
    [[ "$command_parent" == "$trust_root" || "$command_parent" == "$trust_root"/* ]] ||
        [[ "$trust_root" == / && "$command_parent" == /* ]] || return 1
    certificate_owned_chain_safe "$command_parent" "$trust_root" "$expected_uid"
}

certificate_deploy_boundary_safe() {
    local base_real deploy_real trust_root path expected_uid
    [[ -d "$CERT_DEPLOY_BASE" && ! -L "$CERT_DEPLOY_BASE" ]] || return 1
    [[ -d "$CERT_DEPLOY_ROOT" && ! -L "$CERT_DEPLOY_ROOT" ]] || return 1
    [[ -d "$CERT_DEPLOY_ROOT/generations" && ! -L "$CERT_DEPLOY_ROOT/generations" ]] || return 1
    base_real=$(readlink -f -- "$CERT_DEPLOY_BASE" 2>/dev/null) || return 1
    deploy_real=$(readlink -f -- "$CERT_DEPLOY_ROOT" 2>/dev/null) || return 1
    [[ "$CERT_DEPLOY_BASE" == "$base_real" && "$CERT_DEPLOY_ROOT" == "$deploy_real" ]] || return 1
    [[ "${deploy_real%/*}" == "$base_real" ]] || return 1
    if [[ ${VPS_CERT_ALLOW_UNSAFE_TEST_HOOKS:-no} == yes ]]; then
        expected_uid=$(id -u)
    else
        expected_uid=0
    fi
    trust_root=${VPS_CERT_DEPLOY_TRUST_ROOT:-/}
    trust_root=$(readlink -f -- "$trust_root" 2>/dev/null) || return 1
    certificate_owned_chain_safe "$base_real" "$trust_root" "$expected_uid" || return 1
    for path in "$CERT_DEPLOY_BASE" "$CERT_DEPLOY_ROOT" "$CERT_DEPLOY_ROOT/generations"; do
        certificate_owned_path_safe "$path" "$expected_uid" || return 1
    done
}

certificate_port_valid() {
    [[ ${1:-} =~ ^[0-9]+$ ]] && (( 1 <= $1 && $1 <= 65535 ))
}

certificate_hook_safe() {
    local hook=${1:-} uid mode
    [[ -z "$hook" ]] && return 0
    certificate_path_is_absolute "$hook" || return 1
    [[ -f "$hook" && -x "$hook" && ! -L "$hook" ]] || return 1
    if [[ ${VPS_CERT_ALLOW_UNSAFE_TEST_HOOKS:-no} == yes ]]; then
        return 0
    fi
    uid=$(stat -c %u "$hook" 2>/dev/null || true)
    mode=$(stat -c %a "$hook" 2>/dev/null || true)
    [[ "$uid" == 0 ]] || return 1
    [[ "$mode" =~ ^[0-7][0145][0145]$ ]]
}

certificate_config_validate() {
    local required_paths=() path hook pair uid mode deploy_leaf deploy_relative
    [[ "$CERT_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$CERT_DOMAIN" == *.* ]] || {
        printf '域名配置缺失或格式无效；具体值未显示。\n' >&2
        return 30
    }
    required_paths=("$CERT_ACME_CLIENT" "$CERT_ACME_DOMAIN_CONF" "$CERT_ACME_CERT_FILE" "$CERT_ACME_KEY_FILE" \
        "$CERT_DEPLOY_ROOT" "$CERT_VPS_COMMAND")
    for path in "${required_paths[@]}"; do
        certificate_path_is_absolute "$path" || {
            printf '证书生命周期配置包含缺失或非绝对路径；具体值未显示。\n' >&2
            return 30
        }
    done
    [[ "$CERT_ACME_CERT_FILE" != "$CERT_ACME_KEY_FILE" ]] || {
        printf '证书和私钥源路径不能相同。\n' >&2
        return 30
    }
    certificate_path_is_absolute "$CERT_DEPLOY_BASE" || return 30
    deploy_leaf=${CERT_DEPLOY_ROOT##*/}
    deploy_relative=${CERT_DEPLOY_ROOT#"$CERT_DEPLOY_BASE"/}
    [[ "$CERT_DEPLOY_ROOT" == "$CERT_DEPLOY_BASE"/* && "$deploy_relative" != */* &&
       "$deploy_leaf" =~ ^[A-Za-z0-9._-]+$ && "$deploy_leaf" != . && "$deploy_leaf" != .. ]] || {
        printf '部署根目录必须是受控证书目录下的单个安全节点目录。\n' >&2
        return 30
    }
    case "$CERT_ACME_CERT_FILE" in
        "$CERT_DEPLOY_ROOT"/*) printf 'ACME 源文件不能位于模块部署目录内。\n' >&2; return 30 ;;
    esac
    case "$CERT_ACME_KEY_FILE" in
        "$CERT_DEPLOY_ROOT"/*) printf 'ACME 源文件不能位于模块部署目录内。\n' >&2; return 30 ;;
    esac
    case "$CERT_ACME_DOMAIN_CONF" in
        "$CERT_DEPLOY_ROOT"/*) printf 'ACME 域名配置不能位于模块部署目录内。\n' >&2; return 30 ;;
    esac
    if ! certificate_command_path_syntax_safe "$CERT_ACME_CLIENT" ||
       ! certificate_command_path_syntax_safe "$CERT_VPS_COMMAND"; then
        printf 'root 执行文件路径包含不安全字符。\n' >&2
        return 30
    fi
    [[ "$CERT_ACME_ECC" =~ ^(yes|no)$ ]] || {
        printf 'acme_ecc 只能为 yes 或 no。\n' >&2
        return 30
    }
    [[ "$CERT_SERVICE_UNIT" =~ ^[A-Za-z0-9@_.-]+$ ]] || {
        printf '服务单元配置缺失或格式无效。\n' >&2
        return 30
    }
    [[ "$CERT_SERVICE_ACTION" =~ ^(reload|restart)$ ]] || {
        printf 'service_action 只能为 reload 或 restart。\n' >&2
        return 30
    }
    [[ "$CERT_CRON_KIND" =~ ^(system|user)$ ]] || {
        printf 'cron_kind 只能为 system 或 user。\n' >&2
        return 30
    }
    [[ "$CERT_CRON_USER" == root ]] || {
        printf '当前版本只允许 root 执行证书生命周期任务。\n' >&2
        return 30
    }
    [[ "$CERT_MIN_VALIDITY_SECONDS" =~ ^[0-9]+$ ]] || {
        printf 'min_validity_seconds 必须为非负整数。\n' >&2
        return 30
    }
    if [[ "$CERT_CRON_KIND" == system ]]; then
        certificate_path_is_absolute "$CERT_CRON_FILE" || {
            printf '系统 cron 文件必须使用绝对路径。\n' >&2
            return 30
        }
        if [[ ${VPS_CERT_ALLOW_UNSAFE_TEST_HOOKS:-no} != yes ]]; then
            case "$CERT_CRON_FILE" in
                /etc/cron.d/*) ;;
                *) printf '系统 cron 文件必须位于 /etc/cron.d。\n' >&2; return 30 ;;
            esac
        fi
    fi
    for pair in "$CERT_LOCAL_PORT" "$CERT_DIRECT_PORT" "$CERT_FORWARD_PORT"; do
        [[ -z "$pair" ]] || certificate_port_valid "$pair" || {
            printf '健康检查端口格式无效；具体值未显示。\n' >&2
            return 30
        }
    done
    if [[ -n "$CERT_DIRECT_HOST" || -n "$CERT_DIRECT_PORT" ]]; then
        [[ -n "$CERT_DIRECT_HOST" && -n "$CERT_DIRECT_PORT" ]] || {
            printf '直连 TLS 健康检查必须同时配置地址和端口。\n' >&2
            return 30
        }
    fi
    if [[ -n "$CERT_FORWARD_HOST" || -n "$CERT_FORWARD_PORT" ]]; then
        [[ -n "$CERT_FORWARD_HOST" && -n "$CERT_FORWARD_PORT" ]] || {
            printf '转发 TLS 健康检查必须同时配置地址和端口。\n' >&2
            return 30
        }
    fi
    for hook in "$CERT_PANEL_HEALTHCHECK" "$CERT_REALITY_HEALTHCHECK" "$CERT_VLESS_HEALTHCHECK"; do
        certificate_hook_safe "$hook" || {
            printf '协议健康检查程序必须是 root 拥有且不可被组或其他用户写入的本机可执行文件。\n' >&2
            return 30
        }
    done
    if [[ -r "$CONFIG_FILE" && ${VPS_CERT_ALLOW_UNSAFE_TEST_HOOKS:-no} != yes ]]; then
        uid=$(stat -c %u "$CONFIG_FILE" 2>/dev/null || true)
        mode=$(stat -c %a "$CONFIG_FILE" 2>/dev/null || true)
        [[ "$uid" == 0 && "$mode" =~ ^[0-7][0145][0145]$ ]] || {
            printf '证书生命周期配置必须由 root 拥有，且不可被组或其他用户写入。\n' >&2
            return 30
        }
    fi
}

certificate_check() {
    certificate_supported_platform || return $?
    command -v openssl >/dev/null 2>&1 || {
        printf '缺少 openssl。\n' >&2
        return 30
    }
    command -v systemctl >/dev/null 2>&1 || {
        printf '缺少 systemctl。\n' >&2
        return 30
    }
    command -v flock >/dev/null 2>&1 || {
        printf '缺少 flock，无法阻止证书事务并发执行。\n' >&2
        return 30
    }
    certificate_load_config || return $?
    certificate_config_validate || return $?
    certificate_deploy_boundary_safe || {
        printf '证书部署目录越界、为符号链接，或所有权/权限不安全。\n' >&2
        return 30
    }
    certificate_root_executable_safe "$CERT_ACME_CLIENT" || {
        printf 'ACME 客户端真实路径、所有权或权限不安全。\n' >&2
        return 30
    }
    [[ -f "$CERT_ACME_DOMAIN_CONF" && ! -L "$CERT_ACME_DOMAIN_CONF" ]] || {
        printf 'ACME 域名配置不存在或不是普通文件；具体路径未显示。\n' >&2
        return 30
    }
    if [[ ${VPS_CERT_ALLOW_UNSAFE_TEST_HOOKS:-no} != yes ]]; then
        local acme_uid acme_mode
        acme_uid=$(stat -c %u "$CERT_ACME_DOMAIN_CONF" 2>/dev/null || true)
        acme_mode=$(stat -c %a "$CERT_ACME_DOMAIN_CONF" 2>/dev/null || true)
        [[ "$acme_uid" == 0 && "$acme_mode" =~ ^[0-7][0145][0145]$ ]] || {
            printf 'ACME 域名配置必须由 root 拥有，且不可被组或其他用户写入。\n' >&2
            return 30
        }
        [[ ${CERT_ACME_CLIENT##*/} == acme.sh ]] || {
            printf '当前事务适配器只支持明确的 acme.sh 客户端。\n' >&2
            return 30
        }
    fi
    certificate_root_executable_safe "$CERT_VPS_COMMAND" || {
        printf 'vps 命令真实路径、所有权或权限不安全。\n' >&2
        return 30
    }
    if [[ "$CERT_CRON_KIND" == user ]]; then
        command -v crontab >/dev/null 2>&1 || {
            printf '个人 crontab 模式需要 crontab 命令。\n' >&2
            return 30
        }
    fi
}

certificate_public_key_digest_cert() {
    openssl x509 -in "$1" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null |
        openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
}

certificate_public_key_digest_key() {
    openssl pkey -in "$1" -pubout -outform DER 2>/dev/null |
        openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
}

certificate_pair_valid() {
    local cert=$1 key=$2 cert_digest key_digest
    [[ -r "$cert" && -r "$key" ]] || return 1
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
    cert_digest=$(certificate_public_key_digest_cert "$cert") || return 1
    key_digest=$(certificate_public_key_digest_key "$key") || return 1
    [[ -n "$cert_digest" && "$cert_digest" == "$key_digest" ]]
}

certificate_cert_covers_domain() {
    openssl x509 -in "$1" -noout -checkhost "$CERT_DOMAIN" >/dev/null 2>&1
}

certificate_private_key_safe() {
    local key=$1 uid mode
    [[ ${VPS_CERT_ALLOW_UNSAFE_TEST_HOOKS:-no} == yes ]] && return 0
    uid=$(stat -c %u "$key" 2>/dev/null || true)
    mode=$(stat -c %a "$key" 2>/dev/null || true)
    [[ "$uid" == 0 && "$mode" =~ ^[0-7]00$ ]]
}

certificate_cert_fingerprint() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null |
        sed 's/^[^=]*=//; s/://g'
}

certificate_cert_valid_for() {
    openssl x509 -in "$1" -noout -checkend "$2" >/dev/null 2>&1
}

certificate_cert_metadata() {
    local cert=$1 expiry issuer fingerprint
    expiry=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
    issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    fingerprint=$(certificate_cert_fingerprint "$cert")
    printf '证书到期时间: %s\n' "${expiry:-无法读取}"
    printf '证书签发者: %s\n' "${issuer:-无法读取}"
    printf '证书 SHA-256 指纹: %s\n' "${fingerprint:-无法读取}"
}

certificate_source_validate() {
    certificate_pair_valid "$CERT_ACME_CERT_FILE" "$CERT_ACME_KEY_FILE" || {
        printf 'ACME 源证书与私钥无效或不匹配；具体路径和内容未显示。\n' >&2
        return 30
    }
    certificate_cert_covers_domain "$CERT_ACME_CERT_FILE" || {
        printf 'ACME 源证书不覆盖配置的域名；具体名称未显示。\n' >&2
        return 30
    }
    certificate_private_key_safe "$CERT_ACME_KEY_FILE" || {
        printf 'ACME 源私钥必须由 root 独占读取；具体路径未显示。\n' >&2
        return 30
    }
    certificate_cert_valid_for "$CERT_ACME_CERT_FILE" "$CERT_MIN_VALIDITY_SECONDS" || {
        printf 'ACME 源证书剩余有效期不足，拒绝部署。\n' >&2
        return 30
    }
}

certificate_acme_domain_is_side_effect_free() {
    awk -F= -v expected_domain="$CERT_DOMAIN" '
        function unquote(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if ((value ~ /^\047.*\047$/) || (value ~ /^\042.*\042$/)) {
                value = substr(value, 2, length(value) - 2)
            }
            return value
        }
        $1 == "Le_Domain" {
            domain_count++
            domain_value = unquote(substr($0, index($0, "=") + 1))
        }
        $1 ~ /^(Le_RealCertPath|Le_RealKeyPath|Le_RealCACertPath|Le_RealFullChainPath|Le_ReloadCmd|Le_PreHook|Le_PostHook|Le_RenewHook|Le_DeployHook)$/ {
            value = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value != "" && value != "\047\047" && value != "\042\042" &&
                value != "no" && value != "\047no\047" && value != "\042no\042") {
                unsafe = 1
            }
        }
        END { exit(unsafe || domain_count != 1 || domain_value != expected_domain ? 1 : 0) }
    ' "$CERT_ACME_DOMAIN_CONF"
}

certificate_other_acme_schedule_exists() {
    local cron_root=${VPS_CERT_SYSTEM_CRON_ROOT:-/etc} file
    if certificate_user_cron_text |
       grep -Ev 'vps-secure:security\.certificate' |
       grep -Eq 'acme\.sh.*--(cron|renew)'; then
        return 0
    fi
    for file in "$cron_root/crontab" "$cron_root"/cron.d/*; do
        [[ -f "$file" ]] || continue
        [[ "$CERT_CRON_KIND" != system || "$file" != "$CERT_CRON_FILE" ]] || continue
        grep -Ev 'vps-secure:security\.certificate' "$file" 2>/dev/null |
            grep -Eq 'acme\.sh.*--(cron|renew)' && return 0
    done
    return 1
}

certificate_current_target() {
    local current="$CERT_DEPLOY_ROOT/current" target
    [[ -L "$current" ]] || return 1
    target=$(readlink "$current") || return 1
    [[ "$target" =~ ^generations/[A-Za-z0-9._-]+$ ]] || return 1
    [[ "$target" != *..* && -d "$CERT_DEPLOY_ROOT/$target" ]] || return 1
    printf '%s\n' "$target"
}

certificate_current_cert() {
    local target
    target=$(certificate_current_target) || return 1
    printf '%s/%s/fullchain.pem\n' "$CERT_DEPLOY_ROOT" "$target"
}

certificate_current_key() {
    local target
    target=$(certificate_current_target) || return 1
    printf '%s/%s/key.pem\n' "$CERT_DEPLOY_ROOT" "$target"
}

certificate_cron_command() {
    printf '%s module run security.certificate apply --yes --cron >/dev/null' "$CERT_VPS_COMMAND"
}

certificate_cron_line() {
    local command
    command=$(certificate_cron_command)
    if [[ "$CERT_CRON_KIND" == system ]]; then
        printf '17 3 * * * %s %s %s\n' "$CERT_CRON_USER" "$command" "$CRON_TAG"
    else
        printf '17 3 * * * %s %s\n' "$command" "$CRON_TAG"
    fi
}

certificate_user_cron_text() {
    crontab -l 2>/dev/null || true
}

certificate_personal_cron_has_username_field() {
    certificate_user_cron_text | awk '
        ($1 ~ /^[0-9*\/,-]+$/ && $2 ~ /^[0-9*\/,-]+$/ &&
         $3 ~ /^[0-9*\/,-]+$/ && $4 ~ /^[0-9*\/,-]+$/ &&
         $5 ~ /^[0-9*\/,-]+$/ && $6 == "root" &&
         $0 ~ /(acme\.sh|security\.certificate)/) { found = 1 }
        ($1 ~ /^@(daily|hourly|weekly|monthly|reboot)$/ && $2 == "root" &&
         $0 ~ /(acme\.sh|security\.certificate)/) { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

certificate_cron_verify() {
    local expected
    expected=$(certificate_cron_line)
    if [[ "$CERT_CRON_KIND" == system ]]; then
        [[ -f "$CERT_CRON_FILE" && ! -L "$CERT_CRON_FILE" ]] || return 1
        grep -Fxq "$expected" "$CERT_CRON_FILE"
    else
        certificate_personal_cron_has_username_field && return 1
        certificate_user_cron_text | grep -Fxq "$expected"
    fi
}

certificate_system_cron_owned_only() {
    [[ -f "$CERT_CRON_FILE" && ! -L "$CERT_CRON_FILE" ]] || return 1
    awk -v tag="$CRON_TAG" '
        /^[[:space:]]*$/ { next }
        /^SHELL=\/bin\/sh$/ { next }
        /^PATH=\/usr\/local\/sbin:\/usr\/local\/bin:\/usr\/sbin:\/usr\/bin:\/sbin:\/bin$/ { next }
        index($0, tag) { tagged++; next }
        { foreign = 1 }
        END { exit(foreign || tagged != 1 ? 1 : 0) }
    ' "$CERT_CRON_FILE"
}

certificate_cron_backup() {
    local transaction_dir=$1
    printf '%s\n' "$CERT_CRON_KIND" > "$transaction_dir/cron_kind" || return 1
    if [[ "$CERT_CRON_KIND" == system ]]; then
        if [[ -f "$CERT_CRON_FILE" && ! -L "$CERT_CRON_FILE" ]]; then
            printf 'yes\n' > "$transaction_dir/cron_existed" || return 1
            cp -p "$CERT_CRON_FILE" "$transaction_dir/cron.previous" || return 1
        else
            printf 'no\n' > "$transaction_dir/cron_existed" || return 1
        fi
    else
        certificate_user_cron_text | grep -F "$CRON_TAG" > "$transaction_dir/cron.previous" || true
        chmod 600 "$transaction_dir/cron.previous" || return 1
    fi
}

certificate_cron_install() {
    local expected temporary current
    expected=$(certificate_cron_line)
    certificate_cron_verify && return 10
    if [[ "$CERT_CRON_KIND" == system ]]; then
        [[ ! -e "$CERT_CRON_FILE" || ( -f "$CERT_CRON_FILE" && ! -L "$CERT_CRON_FILE" ) ]] || {
            printf '拒绝覆盖非普通文件的系统 cron 入口。\n' >&2
            return 40
        }
        if [[ -e "$CERT_CRON_FILE" ]] && ! certificate_system_cron_owned_only; then
            printf '系统 cron 文件包含非本模块内容；拒绝覆盖。\n' >&2
            return 30
        fi
        temporary="${CERT_CRON_FILE}.tmp.$$"
        {
            printf 'SHELL=/bin/sh\n'
            printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
            printf '%s\n' "$expected"
        } > "$temporary" || return 40
        chmod 644 "$temporary" || { rm -f "$temporary"; return 40; }
        mv -f "$temporary" "$CERT_CRON_FILE" || { rm -f "$temporary"; return 40; }
    else
        certificate_personal_cron_has_username_field && {
            printf '个人 crontab 含疑似系统格式的证书任务；为避免误删其他任务，apply 已停止。\n' >&2
            return 30
        }
        temporary=$(mktemp) || return 40
        current=$(certificate_user_cron_text)
        printf '%s\n' "$current" | grep -Fv "$CRON_TAG" > "$temporary" || true
        printf '%s\n' "$expected" >> "$temporary" || { rm -f "$temporary"; return 40; }
        crontab "$temporary" >/dev/null 2>&1 || { rm -f "$temporary"; return 40; }
        rm -f "$temporary"
    fi
}

certificate_cron_restore() {
    local transaction_dir=$1 kind existed temporary current
    if [[ ${VPS_CERT_ALLOW_UNSAFE_TEST_HOOKS:-no} == yes &&
          ${VPS_TEST_CERT_FAIL_CRON_RESTORE:-no} == yes ]]; then
        return 60
    fi
    [[ -r "$transaction_dir/cron_kind" ]] || return 60
    IFS= read -r kind < "$transaction_dir/cron_kind"
    if [[ "$kind" == system ]]; then
        [[ -r "$transaction_dir/cron_existed" ]] || return 60
        IFS= read -r existed < "$transaction_dir/cron_existed"
        if [[ "$existed" == yes ]]; then
            [[ -f "$transaction_dir/cron.previous" ]] || return 60
            install -m 644 "$transaction_dir/cron.previous" "$CERT_CRON_FILE" || return 60
        else
            rm -f "$CERT_CRON_FILE" || return 60
        fi
    elif [[ "$kind" == user ]]; then
        temporary=$(mktemp) || return 60
        current=$(certificate_user_cron_text)
        printf '%s\n' "$current" | grep -Fv "$CRON_TAG" > "$temporary" || true
        [[ ! -s "$transaction_dir/cron.previous" ]] || cat "$transaction_dir/cron.previous" >> "$temporary"
        crontab "$temporary" >/dev/null 2>&1 || { rm -f "$temporary"; return 60; }
        rm -f "$temporary"
    else
        return 60
    fi
}

certificate_transaction_backup() {
    local transaction_dir previous_target
    transaction_dir=$(vps_new_transaction_dir "$MODULE_ID") || return 40
    if previous_target=$(certificate_current_target 2>/dev/null); then
        printf '%s\n' "$previous_target" > "$transaction_dir/previous_target" || return 40
    else
        printf 'absent\n' > "$transaction_dir/previous_target" || return 40
    fi
    certificate_cron_backup "$transaction_dir" || return 40
    if [[ -r "$CONFIG_FILE" ]]; then
        install -m 600 "$CONFIG_FILE" "$transaction_dir/config.snapshot" || return 40
    fi
    {
        printf 'deploy_root=%s\n' "$CERT_DEPLOY_ROOT"
        printf 'service_unit=%s\n' "$CERT_SERVICE_UNIT"
        printf 'service_action=%s\n' "$CERT_SERVICE_ACTION"
        printf 'cron_kind=%s\n' "$CERT_CRON_KIND"
        printf 'cron_file=%s\n' "$CERT_CRON_FILE"
    } > "$transaction_dir/restore-context" || return 40
    chmod 600 "$transaction_dir/restore-context" || return 40
    printf '%s\n' "$transaction_dir"
}

certificate_restore_context_matches() {
    local transaction_dir=$1 line key value seen='|'
    [[ -r "$transaction_dir/restore-context" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        key=${line%%=*}
        value=${line#*=}
        [[ "$seen" != *"|$key|"* ]] || return 1
        seen+="$key|"
        case "$key" in
            deploy_root) [[ "$CERT_DEPLOY_ROOT" == "$value" ]] || return 1 ;;
            service_unit) [[ "$CERT_SERVICE_UNIT" == "$value" ]] || return 1 ;;
            service_action) [[ "$CERT_SERVICE_ACTION" == "$value" ]] || return 1 ;;
            cron_kind) [[ "$CERT_CRON_KIND" == "$value" ]] || return 1 ;;
            cron_file) [[ "$CERT_CRON_FILE" == "$value" ]] || return 1 ;;
            *) return 1 ;;
        esac
    done < "$transaction_dir/restore-context"
    [[ "$seen" == *'|deploy_root|'* && "$seen" == *'|service_unit|'* &&
       "$seen" == *'|service_action|'* && "$seen" == *'|cron_kind|'* &&
       "$seen" == *'|cron_file|'* ]]
}

certificate_lock_acquire() {
    local module_state
    module_state=$(vps_module_state_dir "$MODULE_ID") || return 1
    install -d -m 700 "$module_state" || return 1
    exec 9> "$module_state/apply.lock" || return 1
    chmod 600 "$module_state/apply.lock" || return 1
    flock -n 9
}

certificate_discard_transaction() {
    local transaction_dir=$1 module_state
    module_state=$(vps_module_state_dir "$MODULE_ID") || return 1
    case "$transaction_dir" in
        "$module_state"/transactions/*) ;;
        *) return 1 ;;
    esac
    rm -f -- "$transaction_dir/previous_target" \
        "$transaction_dir/cron_kind" "$transaction_dir/cron_existed" \
        "$transaction_dir/cron.previous" "$transaction_dir/config.snapshot" \
        "$transaction_dir/restore-context" "$transaction_dir/new_target" \
        "$transaction_dir/compensation-status"
    rmdir "$transaction_dir" 2>/dev/null || true
}

certificate_remove_generation() {
    local target=$1 current=''
    certificate_deploy_boundary_safe || return 1
    [[ "$target" =~ ^generations/[A-Za-z0-9._-]+$ && "$target" != *..* ]] || return 1
    current=$(certificate_current_target 2>/dev/null || true)
    [[ "$current" != "$target" ]] || return 1
    rm -rf -- "${CERT_DEPLOY_ROOT:?}/$target"
}

certificate_preflight() {
    local result=0 current_cert current_key
    certificate_check || return $?
    certificate_acme_domain_is_side_effect_free || {
        printf 'ACME 域名配置与目标域名不一致，或包含外部部署路径/副作用 hook；续期已停止。\n' >&2
        result=30
    }
    certificate_other_acme_schedule_exists && {
        printf '检测到其他 ACME 定时入口；证书生命周期只能保留一个定时所有者。\n' >&2
        result=30
    }
    systemctl is-active --quiet "$CERT_SERVICE_UNIT" 2>/dev/null || {
        printf '目标服务当前未处于 active 状态。\n' >&2
        result=30
    }
    if [[ -e "$CERT_DEPLOY_ROOT/current" && ! -L "$CERT_DEPLOY_ROOT/current" ]]; then
        printf '部署入口 current 不是符号链接，拒绝覆盖。\n' >&2
        result=30
    elif certificate_current_target >/dev/null 2>&1; then
        current_cert=$(certificate_current_cert)
        current_key=$(certificate_current_key)
        certificate_pair_valid "$current_cert" "$current_key" || {
            printf '当前部署代证书与私钥无效或不匹配。\n' >&2
            result=30
        }
    elif [[ -L "$CERT_DEPLOY_ROOT/current" ]]; then
        printf '当前部署链接指向无效或越界位置。\n' >&2
        result=30
    else
        printf '尚未完成受控部署目录的显式接管；apply 不会自动改写服务证书路径。\n' >&2
        result=30
    fi
    if [[ "$CERT_CRON_KIND" == user ]] && certificate_personal_cron_has_username_field; then
        printf '个人 crontab 中存在疑似多余用户名字段的证书任务。\n' >&2
        result=30
    fi
    (( result == 0 )) && printf '证书源、部署边界、服务与定时入口预检通过。\n'
    return "$result"
}

certificate_plan() {
    certificate_load_config || return $?
    certificate_config_validate || return $?
    printf '证书生命周期执行计划：\n'
    printf '  - 调用现有 ACME 客户端执行单域名到期检查，不使用强制续期。\n'
    printf '  - 验证证书、私钥匹配及最短剩余有效期；不会显示私钥内容。\n'
    printf '  - 写入不可变版本目录，并原子切换 current 链接。\n'
    printf '  - 按配置执行一次服务 %s；失败则恢复旧链接。\n' "$CERT_SERVICE_ACTION"
    printf '  - 定时入口类型: %s；个人与系统 cron 使用不同字段结构。\n' "$CERT_CRON_KIND"
    printf '  - 本机监听、直连 TLS、转发 TLS、REALITY 与 VLESS+TLS 分层报告。\n'
    printf '  - 域名、地址、端口及私钥路径默认不显示。\n'
}

certificate_switch_current() {
    local target=$1 temporary="$CERT_DEPLOY_ROOT/.current.$$"
    certificate_deploy_boundary_safe || return 1
    if [[ ${VPS_CERT_ALLOW_UNSAFE_TEST_HOOKS:-no} == yes &&
          ${VPS_TEST_CERT_FAIL_SWITCH_TARGET:-} == "$target" ]]; then
        return 1
    fi
    ln -s "$target" "$temporary" || return 1
    if [[ $(uname -s) == Linux ]]; then
        # GNU mv -T treats the destination symlink itself as the target. This
        # is an atomic rename and never follows current into its directory.
        mv -Tf "$temporary" "$CERT_DEPLOY_ROOT/current" || {
            rm -f "$temporary"
            return 1
        }
    else
        # Non-Linux is used only by the isolated test suite; the module's
        # supported production platforms are Linux. BSD mv follows a symlink
        # to a directory, so use ln's no-dereference replacement semantics.
        rm -f "$temporary"
        ln -sfn "$target" "$CERT_DEPLOY_ROOT/current" || return 1
    fi
}

certificate_remove_current() {
    certificate_deploy_boundary_safe || return 1
    [[ ! -e "$CERT_DEPLOY_ROOT/current" && ! -L "$CERT_DEPLOY_ROOT/current" ]] ||
        rm -f "$CERT_DEPLOY_ROOT/current"
}

certificate_service_apply() {
    systemctl "$CERT_SERVICE_ACTION" "$CERT_SERVICE_UNIT" >/dev/null 2>&1 &&
        systemctl is-active --quiet "$CERT_SERVICE_UNIT" >/dev/null 2>&1
}

certificate_tls_fingerprint() {
    local host=$1 port=$2
    local command=(openssl s_client -connect "$host:$port" -servername "$CERT_DOMAIN" -showcerts)
    if command -v timeout >/dev/null 2>&1; then
        timeout "${VPS_CERT_TLS_TIMEOUT:-10}" "${command[@]}" </dev/null 2>/dev/null |
            openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//; s/://g'
    else
        "${command[@]}" </dev/null 2>/dev/null |
            openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//; s/://g'
    fi
}

certificate_listener_verify() {
    [[ -n "$CERT_LOCAL_PORT" ]] || return 10
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -ltn 2>/dev/null | awk -v suffix=":$CERT_LOCAL_PORT" '
        $4 ~ suffix "$" { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

certificate_tls_endpoint_verify() {
    local host=$1 port=$2 expected=$3 actual
    actual=$(certificate_tls_fingerprint "$host" "$port") || return 1
    [[ -n "$actual" && "$actual" == "$expected" ]]
}

certificate_hook_verify() {
    local hook=${1:-}
    [[ -n "$hook" ]] || return 10
    "$hook" >/dev/null 2>&1
}

certificate_layer_report() {
    local label=$1 result=$2
    case "$result" in
        0) printf '%s: 通过\n' "$label" ;;
        10) printf '%s: 未配置，未验证\n' "$label" ;;
        *) printf '%s: 失败\n' "$label" >&2 ;;
    esac
}

certificate_verify() {
    local current_cert current_key expected result=0 layer
    certificate_check || return 50
    current_cert=$(certificate_current_cert 2>/dev/null) || {
        printf '没有有效的当前证书部署链接。\n' >&2
        return 50
    }
    current_key=$(certificate_current_key 2>/dev/null) || return 50
    certificate_pair_valid "$current_cert" "$current_key" || {
        printf '当前证书与私钥无效或不匹配。\n' >&2
        return 50
    }
    certificate_cert_covers_domain "$current_cert" || {
        printf '当前部署证书不覆盖配置的域名。\n' >&2
        return 50
    }
    certificate_cert_valid_for "$current_cert" "$CERT_MIN_VALIDITY_SECONDS" || {
        printf '当前部署证书剩余有效期不足。\n' >&2
        return 50
    }
    expected=$(certificate_cert_fingerprint "$current_cert") || return 50

    systemctl is-active --quiet "$CERT_SERVICE_UNIT" 2>/dev/null; layer=$?
    certificate_layer_report '管理服务进程' "$layer"
    (( layer == 0 )) || result=50
    certificate_hook_verify "$CERT_PANEL_HEALTHCHECK"; layer=$?
    certificate_layer_report '受控面板访问路径' "$layer"
    (( layer == 0 || layer == 10 )) || result=50

    certificate_listener_verify; layer=$?
    certificate_layer_report '本机监听' "$layer"
    (( layer == 0 || layer == 10 )) || result=50

    if [[ -n "$CERT_DIRECT_HOST" ]]; then
        certificate_tls_endpoint_verify "$CERT_DIRECT_HOST" "$CERT_DIRECT_PORT" "$expected"; layer=$?
    else
        layer=10
    fi
    certificate_layer_report '直连 TLS、SNI 与实际证书' "$layer"
    (( layer == 0 || layer == 10 )) || result=50

    if [[ -n "$CERT_FORWARD_HOST" ]]; then
        certificate_tls_endpoint_verify "$CERT_FORWARD_HOST" "$CERT_FORWARD_PORT" "$expected"; layer=$?
    else
        layer=10
    fi
    certificate_layer_report '转发 TLS 与实际证书' "$layer"
    (( layer == 0 || layer == 10 )) || result=50

    certificate_hook_verify "$CERT_REALITY_HEALTHCHECK"; layer=$?
    certificate_layer_report 'REALITY 协议专项健康' "$layer"
    (( layer == 0 || layer == 10 )) || result=50

    certificate_hook_verify "$CERT_VLESS_HEALTHCHECK"; layer=$?
    certificate_layer_report 'VLESS+TLS 协议专项健康' "$layer"
    (( layer == 0 || layer == 10 )) || result=50

    certificate_cron_verify || {
        printf '定时入口未通过精确语法核对。\n' >&2
        result=50
    }
    (( result == 0 )) || return 50
    printf '证书部署与已配置的分层健康检查通过。\n'
}

certificate_restore_transaction() {
    local transaction_dir=$1 previous_target previous_cert previous_key
    [[ -r "$transaction_dir/previous_target" ]] || return 60
    IFS= read -r previous_target < "$transaction_dir/previous_target"
    if [[ "$previous_target" == absent ]]; then
        printf '事务前没有可恢复的部署代；自动移除当前证书可能中断服务，回滚需要人工确认。\n' >&2
        return 60
    else
        [[ "$previous_target" =~ ^generations/[A-Za-z0-9._-]+$ ]] || return 60
        [[ "$previous_target" != *..* ]] || return 60
        previous_cert="$CERT_DEPLOY_ROOT/$previous_target/fullchain.pem"
        previous_key="$CERT_DEPLOY_ROOT/$previous_target/key.pem"
        certificate_pair_valid "$previous_cert" "$previous_key" || {
            printf '旧部署代证书与私钥无效，拒绝回滚。\n' >&2
            return 60
        }
        certificate_cert_covers_domain "$previous_cert" || {
            printf '旧部署代证书不覆盖当前配置域名，拒绝回滚。\n' >&2
            return 60
        }
        certificate_private_key_safe "$previous_key" || {
            printf '旧部署代私钥权限不安全，拒绝回滚。\n' >&2
            return 60
        }
        certificate_cert_valid_for "$previous_cert" "$CERT_MIN_VALIDITY_SECONDS" || {
            printf '旧部署代证书剩余有效期不足，回滚需要人工确认。\n' >&2
            return 60
        }
        certificate_switch_current "$previous_target" || return 60
    fi
    certificate_cron_restore "$transaction_dir" || return 60
    certificate_service_apply || {
        printf '已恢复部署指针，但服务未能重新加载；需要人工检查。\n' >&2
        return 60
    }
    printf '已恢复应用前的证书部署指针与定时入口。\n'
}

certificate_compensate_transaction() {
    local transaction_dir=$1 previous_target=$2 generation_target=$3
    local link_restored=no cron_restored=no service_restored=no generation_removed=no

    if [[ "$previous_target" == absent ]]; then
        certificate_remove_current && link_restored=yes
    else
        certificate_switch_current "$previous_target" && link_restored=yes
    fi
    certificate_cron_restore "$transaction_dir" && cron_restored=yes
    if [[ "$link_restored" == yes ]] && certificate_service_apply; then
        service_restored=yes
    fi

    if [[ "$link_restored" == yes && "$cron_restored" == yes &&
          "$service_restored" == yes ]]; then
        certificate_remove_generation "$generation_target" && generation_removed=yes
    fi
    {
        printf 'link_restored=%s\n' "$link_restored"
        printf 'cron_restored=%s\n' "$cron_restored"
        printf 'service_restored=%s\n' "$service_restored"
        printf 'generation_removed=%s\n' "$generation_removed"
    } > "$transaction_dir/compensation-status" 2>/dev/null || true
    chmod 600 "$transaction_dir/compensation-status" 2>/dev/null || true

    if [[ "$link_restored" == yes && "$cron_restored" == yes &&
          "$service_restored" == yes && "$generation_removed" == yes ]]; then
        certificate_discard_transaction "$transaction_dir" || {
            printf '旧状态已恢复，但事务证据清理失败；已保留上下文供人工核对。\n' >&2
            return 1
        }
        printf '已核对恢复旧部署链接、旧定时入口与旧服务状态。\n' >&2
        return 0
    fi

    printf '自动补偿未完全成功；已保留事务上下文及可用证书代，需要人工恢复。\n' >&2
    return 1
}

certificate_compensate_cron_only() {
    local transaction_dir=$1 cron_restored=no
    certificate_cron_restore "$transaction_dir" && cron_restored=yes
    {
        printf 'link_restored=not-required\n'
        printf 'cron_restored=%s\n' "$cron_restored"
        printf 'service_restored=not-required\n'
        printf 'generation_removed=not-required\n'
    } > "$transaction_dir/compensation-status" 2>/dev/null || true
    chmod 600 "$transaction_dir/compensation-status" 2>/dev/null || true
    if [[ "$cron_restored" == yes ]]; then
        certificate_discard_transaction "$transaction_dir" || return 1
        printf '已核对恢复原定时入口。\n' >&2
        return 0
    fi
    printf '定时入口补偿失败；已保留事务上下文，需要人工恢复。\n' >&2
    return 1
}

certificate_apply() {
    local cron_run=no transaction_dir acme_result source_fingerprint current_cert current_fingerprint
    local staging generation_name generation_target cron_changed=no cron_was_valid=no switched=no previous_target
    local acme_args=()
    [[ ${1:-} == --cron ]] && cron_run=yes
    vps_require_root || return $?
    certificate_lock_acquire || {
        printf '已有证书生命周期事务正在执行，本次安全跳过。\n' >&2
        return 30
    }
    certificate_preflight || return $?
    transaction_dir=$(certificate_transaction_backup) || return 40
    IFS= read -r previous_target < "$transaction_dir/previous_target"

    acme_args=(--renew -d "$CERT_DOMAIN")
    [[ "$CERT_ACME_ECC" == yes ]] && acme_args+=(--ecc)
    "$CERT_ACME_CLIENT" "${acme_args[@]}" >/dev/null 2>&1
    acme_result=$?
    if (( acme_result != 0 && acme_result != 2 )); then
        printf 'ACME 到期检查或签发失败；现有部署未改变，客户端输出已隐藏。\n' >&2
        certificate_discard_transaction "$transaction_dir" || true
        return 40
    fi
    certificate_source_validate || {
        printf '续期后源文件验证失败；现有部署未改变。\n' >&2
        certificate_discard_transaction "$transaction_dir" || true
        return 40
    }

    certificate_cron_verify && cron_was_valid=yes
    if certificate_cron_install; then
        :
    else
        acme_result=$?
        if (( acme_result == 10 )); then
            :
        else
            certificate_compensate_cron_only "$transaction_dir" || true
            return "$acme_result"
        fi
    fi
    certificate_cron_verify || {
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    [[ "$cron_was_valid" == yes ]] || cron_changed=yes

    source_fingerprint=$(certificate_cert_fingerprint "$CERT_ACME_CERT_FILE") || {
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    if current_cert=$(certificate_current_cert 2>/dev/null); then
        current_fingerprint=$(certificate_cert_fingerprint "$current_cert" 2>/dev/null || true)
        if [[ -n "$current_fingerprint" && "$current_fingerprint" == "$source_fingerprint" ]]; then
            if [[ "$cron_changed" == yes ]]; then
                if ! vps_set_last_transaction "$MODULE_ID" "$transaction_dir"; then
                    printf '无法登记回滚点，开始核对定时入口补偿。\n' >&2
                    certificate_compensate_cron_only "$transaction_dir" || true
                    return 40
                fi
                printf '证书尚无需部署；已安装并核对定时入口，未重载服务。事务记录: %s\n' \
                    "$transaction_dir"
                return 0
            fi
            certificate_discard_transaction "$transaction_dir" || true
            if [[ "$cron_run" == yes ]]; then
                return 0
            fi
            printf '证书尚无需部署；定时入口已核对，未重载服务。\n'
            return 10
        fi
    fi

    certificate_deploy_boundary_safe || {
        printf '部署目录在写入前未通过真实路径复核。\n' >&2
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    install -d -m 700 "$CERT_DEPLOY_ROOT" "$CERT_DEPLOY_ROOT/generations" || {
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    staging="$CERT_DEPLOY_ROOT/.staging.$$"
    [[ ! -e "$staging" ]] || {
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    install -d -m 700 "$staging" || {
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    install -m 644 "$CERT_ACME_CERT_FILE" "$staging/fullchain.pem" || {
        rm -rf -- "$staging"
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    install -m 600 "$CERT_ACME_KEY_FILE" "$staging/key.pem" || {
        rm -rf -- "$staging"
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    if ! certificate_pair_valid "$staging/fullchain.pem" "$staging/key.pem" ||
       ! certificate_cert_covers_domain "$staging/fullchain.pem" ||
       ! certificate_cert_valid_for "$staging/fullchain.pem" "$CERT_MIN_VALIDITY_SECONDS"; then
            rm -rf -- "$staging"
            printf '部署暂存文件验证失败；现有部署未改变。\n' >&2
            certificate_compensate_cron_only "$transaction_dir" || true
            return 40
    fi
    generation_name="$(vps_timestamp)-${source_fingerprint:0:16}-$$"
    generation_target="generations/$generation_name"
    printf '%s\n' "$generation_target" > "$transaction_dir/new_target" || {
        rm -rf -- "$staging"
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    certificate_deploy_boundary_safe || {
        rm -rf -- "$staging"
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    mv "$staging" "$CERT_DEPLOY_ROOT/$generation_target" || {
        rm -rf -- "$staging"
        certificate_compensate_cron_only "$transaction_dir" || true
        return 40
    }
    certificate_switch_current "$generation_target" || {
        certificate_compensate_transaction "$transaction_dir" "$previous_target" \
            "$generation_target" || true
        return 40
    }
    switched=yes

    if ! certificate_service_apply; then
        printf '服务重载或重启失败，开始核对事务补偿。\n' >&2
        certificate_compensate_transaction "$transaction_dir" "$previous_target" \
            "$generation_target" || true
        return 40
    fi
    if ! certificate_verify; then
        printf '部署后分层验证失败，开始核对事务补偿。\n' >&2
        certificate_compensate_transaction "$transaction_dir" "$previous_target" \
            "$generation_target" || true
        return 50
    fi
    [[ "$switched" == yes || "$cron_changed" == yes ]] || return 0
    if ! vps_set_last_transaction "$MODULE_ID" "$transaction_dir"; then
        printf '无法登记回滚点，开始核对事务补偿。\n' >&2
        certificate_compensate_transaction "$transaction_dir" "$previous_target" \
            "$generation_target" || true
        return 40
    fi
    printf '证书已部署为新的不可变版本，并通过已配置的分层验证。事务记录: %s\n' "$transaction_dir"
}

certificate_backup_action() {
    local transaction_dir
    vps_require_root || return $?
    certificate_lock_acquire || {
        printf '已有证书生命周期事务正在执行，未创建备份。\n' >&2
        return 30
    }
    certificate_preflight || return $?
    transaction_dir=$(certificate_transaction_backup) || return 40
    printf '已保存当前部署指针、模块配置和脚本拥有的定时入口；未复制私钥内容，也未替换现有回滚点。备份记录: %s\n' \
        "$transaction_dir"
}

certificate_rollback() {
    local transaction_dir
    vps_require_root || return $?
    certificate_load_config || return 60
    certificate_config_validate || return 60
    transaction_dir=$(vps_last_transaction "$MODULE_ID") || {
        printf '没有可回滚的证书生命周期事务。\n' >&2
        return 60
    }
    certificate_lock_acquire || {
        printf '已有证书生命周期事务正在执行，未执行回滚。\n' >&2
        return 60
    }
    certificate_restore_context_matches "$transaction_dir" || {
        printf '当前配置与事务创建时的恢复边界不同，回滚需要人工确认。\n' >&2
        return 60
    }
    certificate_restore_transaction "$transaction_dir"
}

certificate_status() {
    local current_cert
    certificate_load_config || return 30
    certificate_config_validate || return 30
    if current_cert=$(certificate_current_cert 2>/dev/null); then
        certificate_cert_metadata "$current_cert"
    else
        printf '当前部署: 尚无有效的模块部署代。\n'
    fi
    if certificate_cron_verify; then
        printf '定时入口: 语法与模块配置一致。\n'
    else
        printf '定时入口: 未安装或语法不一致。\n'
    fi
    printf '自然续期状态: 本模块只确认入口和执行结果；尚未据此宣称下一次自然续期已经发生。\n'
}

action=${1:-}
shift || true
case "$action" in
    check) certificate_check ;;
    plan) certificate_plan ;;
    preflight) certificate_preflight ;;
    backup) certificate_backup_action ;;
    apply) certificate_apply "$@" ;;
    verify) certificate_verify ;;
    status|doctor) certificate_status ;;
    rollback) certificate_rollback ;;
    *)
        printf 'security.certificate 不支持操作: %s\n' "$action" >&2
        exit 64
        ;;
esac
