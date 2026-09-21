#!/usr/bin/env bash

# Read-only, redacted diagnostic report helpers. Apart from creating the report
# itself, these functions must not change platform or module state.

vps_report_safe_version() {
    local value=${1:-}
    if [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
        printf '%s\n' "$value"
    else
        printf 'unknown\n'
    fi
}

vps_report_safe_build_id() {
    local value=${1:-}
    if [[ "$value" =~ ^sha256-[a-f0-9]{64}$ ]]; then
        printf '%s\n' "$value"
    else
        printf 'unknown\n'
    fi
}

vps_report_platform_summary() {
    local platform version
    platform=$(vps_platform_id 2>/dev/null || true)
    version=$(vps_platform_version 2>/dev/null || true)
    case "$platform" in
        debian) platform=debian ;;
        ubuntu) platform=ubuntu ;;
        '') platform=unknown ;;
        *) platform=other ;;
    esac
    [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || version=unknown
    printf '%s %s\n' "$platform" "$version"
}

vps_report_module_summary() {
    local manifest entry privilege total=0 ready=0 unavailable=0 third_party=0

    while IFS= read -r manifest; do
        total=$((total + 1))
        if ! vps_validate_manifest "$manifest" >/dev/null 2>&1; then
            unavailable=$((unavailable + 1))
            continue
        fi
        entry=$(vps_manifest_value "$manifest" entry 2>/dev/null || true)
        privilege=$(vps_manifest_value "$manifest" trust 2>/dev/null || true)
        [[ "$privilege" == third-party ]] && third_party=$((third_party + 1))
        if [[ -n "$entry" && -x "$(dirname -- "$manifest")/$entry" ]]; then
            ready=$((ready + 1))
        else
            unavailable=$((unavailable + 1))
        fi
    done < <(vps_module_manifests 2>/dev/null || true)

    if (( total == 0 )); then
        printf '已登记模块: 未知（未发现可读模块登记）\n'
        printf '入口可用: 未知\n'
        printf '入口不可用或描述无效: 未知\n'
        printf '第三方模块: 未知（不读取或复制其配置与状态原文）\n'
        return
    fi
    printf '已登记模块: %s\n' "$total"
    printf '入口可用: %s\n' "$ready"
    printf '入口不可用或描述无效: %s\n' "$unavailable"
    printf '第三方模块: %s（不读取或复制其配置与状态原文）\n' "$third_party"
}

vps_report_transaction_summary() {
    local manifest module_id total=0 present=0

    while IFS= read -r manifest; do
        vps_validate_manifest "$manifest" >/dev/null 2>&1 || continue
        module_id=$(vps_manifest_value "$manifest" id 2>/dev/null || true)
        [[ -n "$module_id" ]] || continue
        total=$((total + 1))
        vps_last_transaction "$module_id" >/dev/null 2>&1 && present=$((present + 1))
    done < <(vps_module_manifests 2>/dev/null || true)

    if (( present > 0 )); then
        printf '最近事务: 存在（%s/%s 个模块有可用记录）\n' "$present" "$total"
    elif (( total > 0 )); then
        printf '最近事务: 未发现可用记录\n'
    else
        printf '最近事务: 未知（无法读取模块登记）\n'
    fi
}

vps_report_ssh_summary() {
    local ports count=0 default=no
    ports=$(vps_require_ssh_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then
        printf 'SSH 端口确认: 未知\n'
        return
    fi
    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        count=$((count + 1))
        [[ "$port" == 22 ]] && default=yes
    done <<< "$ports"
    if (( count == 0 )); then
        printf 'SSH 端口确认: 未知\n'
    else
        [[ "$default" == yes ]] && default=是 || default=否
        printf 'SSH 端口确认: %s 个；包含默认端口: %s\n' "$count" "$default"
    fi
}

vps_report_write_content() {
    local version=${VERSION:-unknown} build_id=${BUILD_ID:-unknown}
    local platform modules transactions ssh_status

    platform=$(vps_report_platform_summary 2>/dev/null || printf 'unknown unknown')
    modules=$(vps_report_module_summary 2>/dev/null || printf '模块摘要: 检查失败')
    transactions=$(vps_report_transaction_summary 2>/dev/null || printf '最近事务: 检查失败')
    ssh_status=$(vps_report_ssh_summary 2>/dev/null || printf 'SSH 端口确认: 检查失败')

    cat <<EOF
VPS Secure 脱敏诊断报告
========================

[平台]
版本: $(vps_report_safe_version "$version")
完整构建身份: $(vps_report_safe_build_id "$build_id")

[系统]
系统族与版本: $platform
systemd: $(vps_has_systemd >/dev/null 2>&1 && printf '可用' || printf '不可用或未运行')
包管理能力: $(vps_package_manager >/dev/null 2>&1 && printf '可用' || printf '不可用')
$ssh_status

[模块登记健康摘要]
$modules

[事务]
$transactions

[下一步]
1. 如有未知、不可用或检查失败，请把本报告交给维护者进一步核对。
2. 本报告不会自动修复、安装、更新、重启、上传或提交任何内容。
3. 分享前请自行检查；如发现服务器身份、网络入口或认证材料，请勿发送。

[默认脱敏边界]
未收集完整 IP、主机名、用户名、域名、真实端口、节点链接、认证参数、密钥正文、
Cookie、令牌、密码、Fail2Ban 封禁地址、认证日志原文、环境变量、命令历史或配置全文。
EOF
}

vps_report_path_is_safe() {
    local path=$1 current=/ part
    local parts=()

    [[ "$path" == /* ]] || return 1
    IFS=/ read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
        [[ ! "$part" =~ [[:cntrl:]] ]] || return 1
        current=${current%/}/$part
        [[ ! -L "$current" ]] || return 1
    done
}

vps_report_file_uid() {
    stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null
}

vps_report_file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

vps_report_file_identity() {
    if stat -c '%d:%i' "$1" >/dev/null 2>&1; then
        stat -c '%d:%i' "$1"
    else
        stat -f '%d:%i' "$1" 2>/dev/null
    fi
}

vps_report_dir_is_trusted() {
    local path=$1 physical uid mode mode_value
    vps_report_path_is_safe "$path" || return 1
    [[ -d "$path" && ! -L "$path" ]] || return 1
    physical=$(cd -- "$path" && pwd -P) || return 1
    [[ "$physical" == "$path" ]] || return 1
    uid=$(vps_report_file_uid "$path") || return 1
    [[ "$uid" == "$EUID" ]] || return 1
    mode=$(vps_report_file_mode "$path") || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0022) == 0 ))
}

vps_report_dir_identity() {
    local path=$1 identity
    vps_report_dir_is_trusted "$path" || return 1
    identity=$(vps_report_file_identity "$path") || return 1
    printf '%s\n' "$identity"
}

vps_report_prepare_state_root() {
    local state_root=$1 parent
    vps_report_path_is_safe "$state_root" || return 1
    case "$state_root" in
        /|/bin|/etc|/home|/private|/private/tmp|/root|/tmp|/usr|/var) return 1 ;;
    esac
    parent=$(dirname -- "$state_root")
    vps_report_dir_is_trusted "$parent" || return 1
    if [[ -e "$state_root" || -L "$state_root" ]]; then
        vps_report_dir_is_trusted "$state_root" || return 1
    else
        mkdir -m 700 "$state_root" || return 1
        vps_report_dir_is_trusted "$state_root" || return 1
    fi
    printf '%s\n' "$state_root"
}

vps_report_prepare_dir() {
    local state_root=$1 report_dir="$1/reports"
    vps_report_dir_is_trusted "$state_root" || return 1
    if [[ -e "$report_dir" || -L "$report_dir" ]]; then
        vps_report_dir_is_trusted "$report_dir" || return 1
    else
        mkdir -m 700 "$report_dir" || return 1
        vps_report_dir_is_trusted "$report_dir" || return 1
    fi
    printf '%s\n' "$report_dir"
}

vps_report_create() {
    local output_name=${1:-}
    local state_root report_dir report_dir_identity current_identity
    local temporary target old_umask

    if [[ -z "$output_name" ]]; then
        output_name="vps-report-$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"
    fi
    [[ "$output_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.txt$ ]] || {
        printf '报告文件名无效；只允许安全的 .txt 文件名，不允许路径。\n' >&2
        return 64
    }

    old_umask=$(umask)
    umask 077
    state_root=$(vps_report_prepare_state_root "$(vps_state_root)") || {
        umask "$old_umask"
        printf '报告目录路径不安全。\n' >&2
        return 40
    }
    report_dir=$(vps_report_prepare_dir "$state_root") || {
        umask "$old_umask"
        printf '无法安全创建报告目录。\n' >&2
        return 40
    }
    report_dir_identity=$(vps_report_dir_identity "$report_dir") || {
        umask "$old_umask"
        printf '报告目录不可信。\n' >&2
        return 40
    }
    target="$report_dir/$output_name"
    [[ ! -e "$target" && ! -L "$target" ]] || {
        umask "$old_umask"
        printf '拒绝覆盖已有报告文件。\n' >&2
        return 40
    }

    temporary=$(mktemp "$report_dir/.vps-report.XXXXXX") || {
        umask "$old_umask"
        printf '无法安全创建临时报告。\n' >&2
        return 40
    }
    current_identity=$(vps_report_dir_identity "$report_dir" 2>/dev/null || true)
    if [[ "$current_identity" != "$report_dir_identity" ]]; then
        rm -f -- "$temporary"
        umask "$old_umask"
        printf '报告目录在创建过程中发生变化，已安全停止。\n' >&2
        return 40
    fi
    chmod 600 "$temporary" || {
        rm -f -- "$temporary"
        umask "$old_umask"
        return 40
    }
    if ! vps_report_write_content > "$temporary"; then
        rm -f -- "$temporary"
        umask "$old_umask"
        printf '报告生成失败，未保留半成品。\n' >&2
        return 40
    fi
    chmod 600 "$temporary" || {
        rm -f -- "$temporary"
        umask "$old_umask"
        return 40
    }
    current_identity=$(vps_report_dir_identity "$report_dir" 2>/dev/null || true)
    if [[ "$current_identity" != "$report_dir_identity" ]] || \
       [[ -e "$target" || -L "$target" ]]; then
        rm -f -- "$temporary"
        umask "$old_umask"
        printf '报告目录或目标在生成过程中发生变化，已安全停止。\n' >&2
        return 40
    fi
    if ! ln "$temporary" "$target"; then
        rm -f -- "$temporary"
        umask "$old_umask"
        printf '报告保存失败；目标可能已经存在。\n' >&2
        return 40
    fi
    rm -f -- "$temporary"
    umask "$old_umask"
    printf '%s\n' "$target"
}

vps_report_command() {
    local output_name='' report_path
    while (( $# > 0 )); do
        case $1 in
            --output)
                [[ $# -ge 2 && -z "$output_name" ]] || return 64
                output_name=$2
                shift 2
                ;;
            *)
                printf '未知报告参数: %s\n' "$1" >&2
                return 64
                ;;
        esac
    done
    report_path=$(vps_report_create "$output_name") || return $?
    printf '诊断报告已保存: %s\n' "$report_path"
    printf '默认已排除服务器身份、网络入口、认证材料和原始日志。\n'
    printf '分享前请自行打开检查，确认没有不希望公开的信息。\n'
}
