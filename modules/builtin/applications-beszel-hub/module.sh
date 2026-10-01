#!/usr/bin/env bash

set -u

VPS_MODULE_ID=${VPS_MODULE_ID:-applications.beszel-hub}
VPS_MODULE_DIR=${VPS_MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
VPS_PLATFORM_ROOT=${VPS_PLATFORM_ROOT:-$(cd -- "$VPS_MODULE_DIR/../../.." && pwd)}

# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

BESZEL_HUB_SERVICE=${VPS_BESZEL_HUB_SERVICE:-beszel.service}
BESZEL_HUB_DATA_DIR=${VPS_BESZEL_HUB_DATA_DIR:-/var/lib/beszel/beszel_data}
BESZEL_HUB_BACKUP_DIR=${VPS_BESZEL_HUB_BACKUP_DIR:-$(vps_state_root)/backups/beszel-hub}
BESZEL_HUB_STATE_DIR=${VPS_BESZEL_HUB_STATE_DIR:-$(vps_module_state_dir "$VPS_MODULE_ID")}
BESZEL_HUB_HEALTH_URL=${VPS_BESZEL_HUB_HEALTH_URL:-http://127.0.0.1:8090/api/health}
BESZEL_HUB_RCLONE_CONFIG=${VPS_BESZEL_HUB_RCLONE_CONFIG:-/etc/vps-secure/rclone/rclone.conf}
BESZEL_HUB_RCLONE_CONFIG_OWNER_UID=${VPS_BESZEL_HUB_RCLONE_CONFIG_OWNER_UID:-0}
BESZEL_HUB_ONEDRIVE_CONFIG=${VPS_BESZEL_HUB_ONEDRIVE_CONFIG:-/etc/vps-secure/beszel-hub-onedrive.conf}
BESZEL_HUB_ONEDRIVE_SERVICE=${VPS_BESZEL_HUB_ONEDRIVE_SERVICE:-/etc/systemd/system/vps-secure-beszel-hub-onedrive.service}
BESZEL_HUB_ONEDRIVE_TIMER=${VPS_BESZEL_HUB_ONEDRIVE_TIMER:-/etc/systemd/system/vps-secure-beszel-hub-onedrive.timer}
BESZEL_HUB_VPS_COMMAND=${VPS_BESZEL_HUB_VPS_COMMAND:-/usr/local/bin/vps}
BESZEL_HUB_BACKUP_RESULT=${VPS_BESZEL_HUB_BACKUP_RESULT:-$BESZEL_HUB_STATE_DIR/onedrive-last-result}
BESZEL_HUB_VERIFIED_DIR=${VPS_BESZEL_HUB_VERIFIED_DIR:-$BESZEL_HUB_STATE_DIR/verified-onedrive}
BESZEL_HUB_FORMAT=vps-secure-beszel-hub-v1
BESZEL_HUB_SCHEDULE_MARKER='# Managed by VPS Secure: applications.beszel-hub OneDrive schedule'

hub_path_safe() {
    local path=$1
    [[ "$path" == /* && "$path" != / && "$path" != */../* && "$path" != */.. && \
       ! "$path" =~ [[:cntrl:]] ]]
}

hub_data_dir_valid() {
    hub_path_safe "$BESZEL_HUB_DATA_DIR" || {
        printf 'Beszel Hub 数据目录必须是安全的绝对路径。\n' >&2
        return 30
    }
    [[ -d "$BESZEL_HUB_DATA_DIR" && ! -L "$BESZEL_HUB_DATA_DIR" ]] || {
        printf 'Beszel Hub 数据目录不存在、不是目录或是符号链接: %s\n' \
            "$BESZEL_HUB_DATA_DIR" >&2
        return 30
    }
}

hub_data_owner() {
    stat -c '%u:%g' "$BESZEL_HUB_DATA_DIR" 2>/dev/null || \
        stat -f '%u:%g' "$BESZEL_HUB_DATA_DIR" 2>/dev/null
}

hub_service_exists() {
    systemctl show "$BESZEL_HUB_SERVICE" >/dev/null 2>&1
}

hub_service_active() {
    systemctl is-active --quiet "$BESZEL_HUB_SERVICE"
}

hub_check() {
    case $(uname -s 2>/dev/null || true) in
        Linux) ;;
        *) printf 'Beszel Hub 模块首版仅支持 Linux。\n' >&2; return 20 ;;
    esac
    local command
    for command in systemctl tar sha256sum curl mktemp; do
        command -v "$command" >/dev/null 2>&1 || {
            printf '缺少必要命令: %s\n' "$command" >&2
            return 20
        }
    done
    [[ "$BESZEL_HUB_SERVICE" =~ ^[a-zA-Z0-9_.@:][a-zA-Z0-9_.@:-]*$ ]] || {
        printf 'Beszel Hub systemd 服务名无效。\n' >&2
        return 30
    }
    [[ "$BESZEL_HUB_HEALTH_URL" =~ ^https?://[^[:space:][:cntrl:]]+$ ]] || {
        printf 'Beszel Hub 健康地址必须是 HTTP(S) URL。\n' >&2
        return 30
    }
    hub_data_dir_valid || return $?
    hub_service_exists || {
        printf '未找到 Beszel Hub systemd 服务: %s\n' "$BESZEL_HUB_SERVICE" >&2
        return 20
    }
}

hub_plan() {
    printf 'Beszel Hub 安全迁移计划：\n'
    printf '  - 仅管理现有服务 %s，不安装或升级 Beszel。\n' "$BESZEL_HUB_SERVICE"
    printf '  - 数据目录: %s\n' "$BESZEL_HUB_DATA_DIR"
    printf '  - 备份时短暂停止 Hub，归档完整数据并生成 SHA-256。\n'
    printf '  - 恢复前校验摘要、归档路径、链接和格式清单。\n'
    printf '  - 目标原数据先备份；新数据从同盘 staging 原子切换。\n'
    printf '  - 启动或健康验证失败时恢复原数据。\n'
    printf '  - OneDrive 只保存经 rclone crypt 客户端加密的迁移包，不承载实时数据。\n'
    printf '  - OneDrive 测试会重新下载并校验，不删除本地或云端副本。\n'
    printf '  - 不配置 DNS、反向代理、隧道、云盘挂载或双活。\n'
}

hub_status() {
    local state size app_url
    if hub_service_active; then state=active; else state=inactive; fi
    printf 'Beszel Hub 服务: %s (%s)\n' "$BESZEL_HUB_SERVICE" "$state"
    printf '数据目录: %s\n' "$BESZEL_HUB_DATA_DIR"
    if [[ -d "$BESZEL_HUB_DATA_DIR" ]]; then
        size=$(du -sh -- "$BESZEL_HUB_DATA_DIR" 2>/dev/null | awk '{print $1}')
        printf '数据大小: %s\n' "${size:-unknown}"
    else
        printf '数据状态: 不存在\n'
    fi
    printf '健康地址: %s\n' "$BESZEL_HUB_HEALTH_URL"
    app_url=$(systemctl show "$BESZEL_HUB_SERVICE" -p Environment --value 2>/dev/null | \
        tr ' ' '\n' | sed -n 's/^APP_URL=//p' | head -n 1)
    if [[ "$app_url" =~ ^https://[^[:space:][:cntrl:]]+$ ]]; then
        printf '告警链接地址: %s\n' "$app_url"
    else
        printf '告警链接地址: 未设置有效 HTTPS 地址；邮件链接可能指向 localhost。\n'
    fi
}

hub_verify() {
    hub_data_dir_valid >/dev/null || return 50
    hub_service_active || {
        printf 'Beszel Hub 服务未运行。\n' >&2
        return 50
    }
    curl --fail --silent --show-error --max-time 10 -- \
        "$BESZEL_HUB_HEALTH_URL" >/dev/null || {
        printf 'Beszel Hub 本机健康检查失败。\n' >&2
        return 50
    }
    printf 'Beszel Hub 服务和本机健康接口已通过验证。\n'
}

hub_wait_healthy() {
    local attempt
    for ((attempt = 0; attempt < 20; attempt++)); do
        hub_verify >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

hub_parse_backup_args() {
    local output=''
    while (( $# > 0 )); do
        case $1 in
            --output) output=${2:-}; shift 2 ;;
            *) printf '未知参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    if [[ -z "$output" ]]; then
        output="$BESZEL_HUB_BACKUP_DIR/beszel-hub-$(vps_timestamp).tar.gz"
    fi
    hub_path_safe "$output" || {
        printf '备份输出必须是安全的绝对路径。\n' >&2
        return 64
    }
    printf '%s\n' "$output"
}

hub_backup_restore_service() {
    local was_active=$1
    if [[ "$was_active" == yes ]] && ! hub_service_active; then
        systemctl start "$BESZEL_HUB_SERVICE" || return 1
    fi
    if [[ "$was_active" == yes ]]; then
        hub_wait_healthy
    fi
}

hub_backup() {
    local output output_dir staging partial checksum_partial was_active=no rc=0
    vps_require_root || return $?
    hub_check || return $?
    output=$(hub_parse_backup_args "$@") || return $?
    output_dir=$(dirname -- "$output")
    if [[ -e "$output" || -L "$output" || -e "$output.sha256" || -L "$output.sha256" ]]; then
        printf '拒绝覆盖现有备份或摘要: %s\n' "$output" >&2
        return 30
    fi
    if [[ "$output_dir" == "$BESZEL_HUB_BACKUP_DIR" ]]; then
        install -d -m 700 "$output_dir" || return 40
    elif [[ ! -d "$output_dir" || -L "$output_dir" ]]; then
        printf '备份目标目录不存在或是符号链接: %s\n' "$output_dir" >&2
        return 30
    fi
    if find "$BESZEL_HUB_DATA_DIR" -type l -print -quit | grep -q .; then
        printf '数据目录包含符号链接；为保证可安全恢复，拒绝归档。\n' >&2
        return 30
    fi
    if find "$BESZEL_HUB_DATA_DIR" ! -type f ! -type d -print -quit | grep -q .; then
        printf '数据目录包含特殊文件；为保证可安全恢复，拒绝归档。\n' >&2
        return 30
    fi

    staging=$(mktemp -d "$output_dir/.beszel-backup.XXXXXX") || return 40
    partial="$output.partial.$$"
    checksum_partial="$output.sha256.partial.$$"
    umask 077
    if hub_service_active; then
        was_active=yes
        if ! systemctl stop "$BESZEL_HUB_SERVICE"; then
            rm -rf -- "$staging"
            printf '无法停止 Beszel Hub，未创建备份。\n' >&2
            return 40
        fi
    fi
    trap 'hub_backup_restore_service "$was_active" >/dev/null 2>&1 || true; exit 129' HUP
    trap 'hub_backup_restore_service "$was_active" >/dev/null 2>&1 || true; exit 130' INT
    trap 'hub_backup_restore_service "$was_active" >/dev/null 2>&1 || true; exit 143' TERM

    if ! cp -a -- "$BESZEL_HUB_DATA_DIR" "$staging/beszel_data"; then
        rc=40
    elif ! printf '%s\n' \
        "format=$BESZEL_HUB_FORMAT" \
        "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$staging/manifest"; then
        rc=40
    elif ! tar -czf "$partial" -C "$staging" manifest beszel_data; then
        rc=40
    elif ! chmod 600 "$partial"; then
        rc=40
    elif ! sha256sum "$partial" | awk -v name="$(basename -- "$output")" \
        '{print $1 "  " name}' > "$checksum_partial"; then
        rc=40
    elif ! chmod 600 "$checksum_partial"; then
        rc=40
    elif ! mv -- "$partial" "$output"; then
        rc=40
    elif ! mv -- "$checksum_partial" "$output.sha256"; then
        rm -f -- "$output"
        rc=40
    fi

    rm -rf -- "$staging"
    rm -f -- "$partial" "$checksum_partial"
    if ! hub_backup_restore_service "$was_active"; then
        trap - HUP INT TERM
        printf '备份操作后未能恢复 Beszel Hub 原运行状态。\n' >&2
        return 60
    fi
    trap - HUP INT TERM
    (( rc == 0 )) || {
        printf 'Beszel Hub 备份未完成；原服务状态已恢复。\n' >&2
        return "$rc"
    }
    printf 'Beszel Hub 离线备份已创建: %s\n' "$output"
    printf 'SHA-256 摘要: %s.sha256\n' "$output"
}

hub_parse_restore_args() {
    local archive='' checksum_file='' expected=''
    while (( $# > 0 )); do
        case $1 in
            --archive) archive=${2:-}; shift 2 ;;
            --checksum-file) checksum_file=${2:-}; shift 2 ;;
            --sha256) expected=${2:-}; shift 2 ;;
            *) printf '未知参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    [[ -n "$archive" ]] || { printf '恢复需要 --archive。\n' >&2; return 64; }
    hub_path_safe "$archive" || { printf '归档必须是安全的绝对路径。\n' >&2; return 64; }
    [[ -f "$archive" && ! -L "$archive" ]] || {
        printf '归档不存在、不是普通文件或是符号链接。\n' >&2
        return 30
    }
    if [[ -n "$expected" && -n "$checksum_file" ]]; then
        printf '不能同时使用 --sha256 和 --checksum-file。\n' >&2
        return 64
    fi
    if [[ -z "$expected" ]]; then
        [[ -n "$checksum_file" ]] || checksum_file="$archive.sha256"
        hub_path_safe "$checksum_file" || { printf '摘要文件路径无效。\n' >&2; return 64; }
        [[ -f "$checksum_file" && ! -L "$checksum_file" ]] || {
            printf '摘要文件不存在、不是普通文件或是符号链接。\n' >&2
            return 30
        }
        read -r expected _ < "$checksum_file" || return 30
    fi
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || {
        printf 'SHA-256 摘要格式无效。\n' >&2
        return 30
    }
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    printf '%s\t%s\n' "$archive" "$expected"
}

hub_archive_safe() {
    local archive=$1 entry type manifest_count=0 data_count=0
    tar -tzf "$archive" >/dev/null 2>&1 || {
        printf '归档无法读取或不是有效的 tar.gz。\n' >&2
        return 30
    }
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -n "$entry" && ! "$entry" =~ [[:cntrl:]] ]] || {
            printf '归档包含空名称或控制字符。\n' >&2
            return 30
        }
        case "$entry" in
            manifest) manifest_count=$((manifest_count + 1)) ;;
            beszel_data|beszel_data/) data_count=$((data_count + 1)) ;;
            beszel_data/*) ;;
            *) printf '归档包含允许目录之外的路径。\n' >&2; return 30 ;;
        esac
        case "/$entry/" in
            */../*|*/./*) printf '归档包含不安全的路径组件。\n' >&2; return 30 ;;
        esac
    done < <(LC_ALL=C tar -tzf "$archive")
    [[ $manifest_count -eq 1 && $data_count -eq 1 ]] || {
        printf '归档缺少唯一的 manifest 或 beszel_data 目录。\n' >&2
        return 30
    }
    while IFS= read -r type; do
        case "$type" in
            -|d) ;;
            *) printf '归档包含链接或特殊文件，拒绝恢复。\n' >&2; return 30 ;;
        esac
    done < <(LC_ALL=C tar -tvzf "$archive" | cut -c1)
}

hub_manifest_valid() {
    local manifest=$1 line format='' seen=0
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == format=* ]] || continue
        format=${line#format=}
        seen=$((seen + 1))
    done < "$manifest"
    [[ $seen -eq 1 && "$format" == "$BESZEL_HUB_FORMAT" ]]
}

hub_write_restore_state() {
    local transaction=$1 phase=$2
    printf '%s\n' \
        "phase=$phase" \
        "data_dir=$BESZEL_HUB_DATA_DIR" \
        "service=$BESZEL_HUB_SERVICE" \
        > "$transaction/restore-state" || return 1
    chmod 600 "$transaction/restore-state"
}

hub_new_transaction_dir() {
    local transactions transaction
    hub_path_safe "$BESZEL_HUB_STATE_DIR" || {
        printf 'Beszel Hub 状态目录必须是安全的绝对路径。\n' >&2
        return 1
    }
    transactions="$BESZEL_HUB_STATE_DIR/transactions"
    mkdir -p -- "$transactions" || return 1
    [[ -d "$BESZEL_HUB_STATE_DIR" && ! -L "$BESZEL_HUB_STATE_DIR" && \
       -d "$transactions" && ! -L "$transactions" ]] || return 1
    transaction=$(mktemp -d "$transactions/$(vps_timestamp)-$$-XXXXXX") || return 1
    chmod 700 "$BESZEL_HUB_STATE_DIR" "$transactions" \
        "$transaction" || return 1
    printf '%s\n' "$transaction"
}

hub_set_last_transaction() {
    local transaction=$1 temporary
    case "$transaction" in
        "$BESZEL_HUB_STATE_DIR"/transactions/*) ;;
        *) return 1 ;;
    esac
    temporary="$BESZEL_HUB_STATE_DIR/.last_transaction.$$"
    printf '%s\n' "$transaction" > "$temporary" || return 1
    chmod 600 "$temporary" || return 1
    mv -f -- "$temporary" "$BESZEL_HUB_STATE_DIR/last_transaction"
}

hub_compensate_restore() {
    local previous=$1 failed=$2
    local incomplete=no
    systemctl stop "$BESZEL_HUB_SERVICE" >/dev/null 2>&1 || true
    if [[ -e "$BESZEL_HUB_DATA_DIR" || -L "$BESZEL_HUB_DATA_DIR" ]]; then
        if ! mv -- "$BESZEL_HUB_DATA_DIR" "$failed"; then incomplete=yes; fi
    fi
    if [[ -d "$previous" && ! -e "$BESZEL_HUB_DATA_DIR" ]]; then
        mv -- "$previous" "$BESZEL_HUB_DATA_DIR" || incomplete=yes
    else
        incomplete=yes
    fi
    if [[ "$incomplete" == no ]]; then
        systemctl start "$BESZEL_HUB_SERVICE" || incomplete=yes
    fi
    if [[ "$incomplete" == no ]] && ! hub_wait_healthy; then
        incomplete=yes
    fi
    if [[ "$incomplete" == yes ]]; then
        printf 'Beszel Hub 自动恢复未完成；请保留事务目录并人工恢复。\n' >&2
        return 60
    fi
    printf 'Beszel Hub 恢复失败；目标原数据和服务已自动恢复。\n' >&2
}

hub_restore_signal() {
    local status=$1 previous=$2 failed=$3
    if [[ -d "$previous" ]]; then
        hub_compensate_restore "$previous" "$failed" >/dev/null 2>&1 || true
    else
        systemctl start "$BESZEL_HUB_SERVICE" >/dev/null 2>&1 || true
    fi
    exit "$status"
}

hub_restore() {
    local parsed archive expected actual parent staging previous failed transaction transaction_id
    local failure_rc=40 target_owner
    vps_require_root || return $?
    hub_check || return $?
    parsed=$(hub_parse_restore_args "$@") || return $?
    IFS=$'\t' read -r archive expected <<< "$parsed"
    actual=$(sha256sum "$archive" | awk '{print tolower($1)}') || return 30
    [[ "$actual" == "$expected" ]] || {
        printf '归档 SHA-256 不匹配，未停止服务或修改数据。\n' >&2
        return 30
    }
    hub_archive_safe "$archive" || return $?
    hub_service_active || {
        printf '为确保恢复后可验证并自动回退，Beszel Hub 服务必须在恢复前运行。\n' >&2
        return 30
    }
    target_owner=$(hub_data_owner) || {
        printf '无法读取目标数据目录所有者。\n' >&2
        return 30
    }

    parent=$(dirname -- "$BESZEL_HUB_DATA_DIR")
    [[ -d "$parent" && ! -L "$parent" ]] || return 30
    staging=$(mktemp -d "$parent/.beszel-hub-staging.XXXXXX") || return 40
    if ! tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$staging"; then
        rm -rf -- "$staging"
        return 40
    fi
    if ! hub_manifest_valid "$staging/manifest" || \
       [[ ! -d "$staging/beszel_data" || -L "$staging/beszel_data" ]] || \
       find "$staging/beszel_data" -type l -print -quit | grep -q .; then
        rm -rf -- "$staging"
        printf '归档格式清单或解包后数据结构无效。\n' >&2
        return 30
    fi
    chown -R "$target_owner" "$staging/beszel_data" || {
        rm -rf -- "$staging"
        printf '无法把恢复数据调整为目标 Hub 的现有所有者。\n' >&2
        return 40
    }

    transaction=$(hub_new_transaction_dir) || {
        rm -rf -- "$staging"
        return 40
    }
    transaction_id=${transaction##*/}
    previous="$parent/.beszel-hub-previous.$transaction_id"
    failed="$parent/.beszel-hub-failed.$transaction_id"
    if [[ -e "$previous" || -L "$previous" || -e "$failed" || -L "$failed" ]]; then
        rm -rf -- "$staging"
        printf 'Hub 恢复临时路径发生冲突，未修改活动数据。\n' >&2
        return 40
    fi
    umask 077
    if ! systemctl stop "$BESZEL_HUB_SERVICE"; then
        rm -rf -- "$staging"
        return 40
    fi
    trap 'hub_restore_signal 129 "$previous" "$failed"' HUP
    trap 'hub_restore_signal 130 "$previous" "$failed"' INT
    trap 'hub_restore_signal 143 "$previous" "$failed"' TERM
    if ! tar -czf "$transaction/original-data.tar.gz" -C "$BESZEL_HUB_DATA_DIR" . || \
       ! chmod 600 "$transaction/original-data.tar.gz" || \
       ! hub_write_restore_state "$transaction" prepared || \
       ! hub_set_last_transaction "$transaction"; then
        rm -rf -- "$staging"
        if ! systemctl start "$BESZEL_HUB_SERVICE"; then
            trap - HUP INT TERM
            return 60
        fi
        trap - HUP INT TERM
        return 40
    fi

    if ! mv -- "$BESZEL_HUB_DATA_DIR" "$previous"; then
        rm -rf -- "$staging"
        if ! systemctl start "$BESZEL_HUB_SERVICE"; then
            trap - HUP INT TERM
            return 60
        fi
        trap - HUP INT TERM
        return 40
    fi
    if ! mv -- "$staging/beszel_data" "$BESZEL_HUB_DATA_DIR"; then
        failure_rc=40
    elif ! hub_write_restore_state "$transaction" switched; then
        failure_rc=40
    elif ! systemctl start "$BESZEL_HUB_SERVICE"; then
        failure_rc=40
    elif ! hub_wait_healthy; then
        failure_rc=50
    elif ! hub_write_restore_state "$transaction" committed; then
        failure_rc=40
    else
        rm -rf -- "$previous" "$staging"
        trap - HUP INT TERM
        printf 'Beszel Hub 数据已恢复，并通过本机健康验证。\n'
        printf '目标原数据备份: %s/original-data.tar.gz\n' "$transaction"
        return 0
    fi

    if ! hub_compensate_restore "$previous" "$failed"; then
        trap - HUP INT TERM
        return 60
    fi
    hub_write_restore_state "$transaction" compensated || true
    rm -rf -- "$failed" "$staging"
    trap - HUP INT TERM
    return "$failure_rc"
}

hub_offsite_relative_path_safe() {
    [[ ${1:-} =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]]
}

hub_parse_onedrive_args() {
    local remote='' path='roundtrip-tests' config=$BESZEL_HUB_RCLONE_CONFIG
    while (( $# > 0 )); do
        case $1 in
            --remote) remote=${2:-}; shift 2 ;;
            --path) path=${2:-}; shift 2 ;;
            --config) config=${2:-}; shift 2 ;;
            *) printf '未知参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    [[ "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || {
        printf 'OneDrive 加密远端名称无效。\n' >&2
        return 64
    }
    hub_offsite_relative_path_safe "$path" || {
        printf 'OneDrive 目标路径必须是安全的相对路径。\n' >&2
        return 64
    }
    hub_path_safe "$config" || {
        printf 'rclone 配置必须是安全的绝对路径。\n' >&2
        return 64
    }
    printf '%s\t%s\t%s\n' "$remote" "$path" "$config"
}

hub_rclone_config_secure() {
    local config=$1 mode owner
    [[ -f "$config" && ! -L "$config" ]] || {
        printf 'rclone 配置不存在、不是普通文件或是符号链接。\n' >&2
        return 30
    }
    owner=$(stat -c '%u' "$config" 2>/dev/null || stat -f '%u' "$config" 2>/dev/null) || return 30
    mode=$(stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config" 2>/dev/null) || return 30
    [[ "$owner" == "$BESZEL_HUB_RCLONE_CONFIG_OWNER_UID" && "$mode" =~ ^[4-7]00$ ]] || {
        printf 'rclone 配置必须由 root 所有，且组和其他用户没有权限。\n' >&2
        return 30
    }
}

hub_rclone_remote_field() {
    local config=$1 remote=$2 field=$3 redacted
    redacted=$(rclone --config "$config" config redacted "$remote" 2>/dev/null) || return 1
    awk -F ' = ' -v wanted="$field" '$1 == wanted { print $2; found=1 } END { if (!found) exit 1 }' \
        <<< "$redacted"
}

hub_onedrive_remote_valid() {
    local config=$1 remote=$2 type backing backing_name backing_type no_data
    hub_rclone_config_secure "$config" || return $?
    type=$(hub_rclone_remote_field "$config" "$remote" type) || {
        printf '无法读取指定的 rclone 远端。\n' >&2
        return 30
    }
    [[ "$type" == crypt ]] || {
        printf '指定远端不是 rclone crypt，拒绝上传未加密备份。\n' >&2
        return 30
    }
    no_data=$(hub_rclone_remote_field "$config" "$remote" no_data_encryption 2>/dev/null || true)
    [[ "$no_data" != true ]] || {
        printf '指定 crypt 远端已关闭数据加密，拒绝使用。\n' >&2
        return 30
    }
    backing=$(hub_rclone_remote_field "$config" "$remote" remote) || {
        printf 'crypt 远端缺少底层存储配置。\n' >&2
        return 30
    }
    [[ "$backing" == *:* ]] || {
        printf 'crypt 远端指向本地路径，拒绝作为 OneDrive 异地备份。\n' >&2
        return 30
    }
    backing_name=${backing%%:*}
    [[ "$backing_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || return 30
    backing_type=$(hub_rclone_remote_field "$config" "$backing_name" type) || {
        printf '无法读取 crypt 的底层远端。\n' >&2
        return 30
    }
    [[ "$backing_type" == onedrive ]] || {
        printf 'crypt 的底层远端不是 OneDrive。\n' >&2
        return 30
    }
}

hub_onedrive_roundtrip() {
    local parsed remote path config stamp unique_dir unique_id archive name verify_dir remote_archive remote_checksum rc=0
    vps_require_root || return $?
    hub_check || return $?
    command -v rclone >/dev/null 2>&1 || {
        printf '缺少必要命令: rclone\n' >&2
        return 20
    }
    parsed=$(hub_parse_onedrive_args "$@") || return $?
    IFS=$'\t' read -r remote path config <<< "$parsed"
    hub_onedrive_remote_valid "$config" "$remote" || return $?

    install -d -m 700 "$BESZEL_HUB_BACKUP_DIR" || return 40
    stamp=$(vps_timestamp)
    unique_dir=$(mktemp -d "$BESZEL_HUB_BACKUP_DIR/.onedrive-name.XXXXXX") || return 40
    unique_id=${unique_dir##*.}
    rmdir -- "$unique_dir" || return 40
    archive="$BESZEL_HUB_BACKUP_DIR/beszel-hub-onedrive-$stamp-$unique_id.tar.gz"
    hub_backup --output "$archive" || return $?
    name=$(basename -- "$archive")
    remote_archive="$remote:$path/$name"
    remote_checksum="$remote:$path/$name.sha256"
    verify_dir=$(mktemp -d "$BESZEL_HUB_BACKUP_DIR/.onedrive-verify.XXXXXX") || return 40
    chmod 700 "$verify_dir" || { rm -rf -- "$verify_dir"; return 40; }
    trap 'rm -rf -- "$verify_dir"; exit 129' HUP
    trap 'rm -rf -- "$verify_dir"; exit 130' INT
    trap 'rm -rf -- "$verify_dir"; exit 143' TERM

    if ! rclone --config "$config" copyto "$archive" "$remote_archive" --no-traverse; then
        printf 'OneDrive 加密备份上传失败；本地备份已保留。\n' >&2
        rc=40
    elif ! rclone --config "$config" copyto "$archive.sha256" "$remote_checksum" --no-traverse; then
        printf 'OneDrive 摘要上传失败；本地备份和已上传归档均未删除。\n' >&2
        rc=40
    elif ! rclone --config "$config" copyto "$remote_archive" "$verify_dir/$name" --no-traverse || \
         ! rclone --config "$config" copyto "$remote_checksum" "$verify_dir/$name.sha256" --no-traverse; then
        printf 'OneDrive 回读失败；本地和云端副本均未删除。\n' >&2
        rc=40
    elif ! (cd "$verify_dir" && sha256sum -c "$name.sha256" >/dev/null 2>&1); then
        printf 'OneDrive 回读文件的 SHA-256 校验失败；未删除任何副本。\n' >&2
        rc=50
    elif ! hub_verify >/dev/null; then
        printf '云端回读通过，但 Beszel Hub 健康验证失败。\n' >&2
        rc=50
    fi

    rm -rf -- "$verify_dir"
    trap - HUP INT TERM
    (( rc == 0 )) || return "$rc"
    hub_verified_record "$archive" "$remote" "$path" || {
        printf '云端回读通过，但无法记录已验证备份；现有副本均已保留。\n' >&2
        return 40
    }
    printf 'OneDrive 加密备份已完成回读和 SHA-256 校验。\n'
    printf '本地备份: %s\n' "$archive"
    printf '云端逻辑路径: %s:%s/%s\n' "$remote" "$path" "$name"
    printf 'Beszel Hub 本机健康验证: 通过\n'
}

hub_verified_record() {
    local archive=$1 remote=$2 path=$3 name marker temporary digest
    name=$(basename -- "$archive")
    [[ "$name" =~ ^beszel-hub-onedrive-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\.tar\.gz$ ]] || return 40
    hub_path_safe "$BESZEL_HUB_VERIFIED_DIR" || return 40
    install -d -m 700 "$BESZEL_HUB_VERIFIED_DIR" || return 40
    marker="$BESZEL_HUB_VERIFIED_DIR/$name.verified"
    [[ ! -e "$marker" && ! -L "$marker" ]] || return 40
    digest=$(sha256sum "$archive" | awk '{print $1}') || return 40
    [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 40
    temporary=$(mktemp "$BESZEL_HUB_VERIFIED_DIR/.verified.XXXXXX") || return 40
    if ! printf 'archive=%s\nremote=%s\npath=%s\nsha256=%s\nverified_utc=%s\n' \
        "$name" "$remote" "$path" "$digest" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$temporary" || \
       ! chmod 600 "$temporary" || \
       ! mv -- "$temporary" "$marker"; then
        rm -f -- "$temporary"
        return 40
    fi
}

hub_schedule_timezone_safe() {
    local timezone=$1
    [[ "$timezone" == UTC || "$timezone" =~ ^[A-Za-z][A-Za-z0-9_+-]*/[A-Za-z0-9_+/-]+$ ]] || return 1
    [[ "$timezone" == UTC || -e "/usr/share/zoneinfo/$timezone" ]]
}

hub_parse_schedule_args() {
    local remote='' path='scheduled' config=$BESZEL_HUB_RCLONE_CONFIG
    local time='04:30' timezone='Asia/Shanghai'
    while (( $# > 0 )); do
        case $1 in
            --remote) remote=${2:-}; shift 2 ;;
            --path) path=${2:-}; shift 2 ;;
            --config) config=${2:-}; shift 2 ;;
            --time) time=${2:-}; shift 2 ;;
            --timezone) timezone=${2:-}; shift 2 ;;
            *) printf '未知参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    [[ "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || {
        printf 'OneDrive 加密远端名称无效。\n' >&2
        return 64
    }
    hub_offsite_relative_path_safe "$path" || {
        printf 'OneDrive 目标路径必须是安全的相对路径。\n' >&2
        return 64
    }
    if ! hub_path_safe "$config" || [[ "$config" =~ [[:space:]] ]]; then
        printf 'rclone 配置必须是不含空白字符的安全绝对路径。\n' >&2
        return 64
    fi
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || {
        printf '每日备份时间必须使用 24 小时 HH:MM 格式。\n' >&2
        return 64
    }
    hub_schedule_timezone_safe "$timezone" || {
        printf '时区名称无效或系统中不存在。\n' >&2
        return 64
    }
    printf '%s\t%s\t%s\t%s\t%s\n' "$remote" "$path" "$config" "$time" "$timezone"
}

hub_schedule_file_owned_or_absent() {
    local file=$1
    if [[ ! -e "$file" && ! -L "$file" ]]; then
        return 0
    fi
    [[ -f "$file" && ! -L "$file" ]] || {
        printf '定时备份文件不是普通文件或是符号链接: %s\n' "$file" >&2
        return 30
    }
    grep -Fxq "$BESZEL_HUB_SCHEDULE_MARKER" "$file" || {
        printf '拒绝覆盖非平台所有的定时备份文件: %s\n' "$file" >&2
        return 30
    }
}

hub_schedule_unit_name() {
    basename -- "$1"
}

hub_schedule_render() {
    local directory=$1 remote=$2 path=$3 config=$4 time=$5 timezone=$6
    local service timer
    service=$(hub_schedule_unit_name "$BESZEL_HUB_ONEDRIVE_SERVICE")
    timer=$(hub_schedule_unit_name "$BESZEL_HUB_ONEDRIVE_TIMER")
    printf '%s\n' \
        "$BESZEL_HUB_SCHEDULE_MARKER" \
        "remote=$remote" \
        "path=$path" \
        "rclone_config=$config" \
        "time=$time" \
        "timezone=$timezone" \
        "retention_days=30" \
        "retention_min_copies=7" \
        "retention_enabled=no" > "$directory/config" || return 1
    cat > "$directory/service" <<EOF
$BESZEL_HUB_SCHEDULE_MARKER
[Unit]
Description=VPS Secure verified Beszel Hub backup to OneDrive
Wants=network-online.target
After=network-online.target $BESZEL_HUB_SERVICE
ConditionPathExists=$config

[Service]
Type=oneshot
UMask=0077
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=30min
ExecStart=$BESZEL_HUB_VPS_COMMAND monitor hub onedrive-run --yes
EOF
    cat > "$directory/timer" <<EOF
$BESZEL_HUB_SCHEDULE_MARKER
[Unit]
Description=Schedule verified Beszel Hub backups to OneDrive

[Timer]
OnCalendar=*-*-* $time:00 $timezone
RandomizedDelaySec=10min
AccuracySec=1min
Persistent=true
Unit=$service

[Install]
WantedBy=timers.target
EOF
    chmod 600 "$directory/config" || return 1
    chmod 644 "$directory/service" "$directory/timer" || return 1
    [[ "$timer" == *.timer ]]
}

hub_schedule_restore_files() {
    local backup=$1 config_had=$2 service_had=$3 timer_had=$4
    if [[ "$config_had" == yes ]]; then
        install -m 600 "$backup/config" "$BESZEL_HUB_ONEDRIVE_CONFIG" || return 1
    else
        rm -f -- "$BESZEL_HUB_ONEDRIVE_CONFIG" || return 1
    fi
    if [[ "$service_had" == yes ]]; then
        install -m 644 "$backup/service" "$BESZEL_HUB_ONEDRIVE_SERVICE" || return 1
    else
        rm -f -- "$BESZEL_HUB_ONEDRIVE_SERVICE" || return 1
    fi
    if [[ "$timer_had" == yes ]]; then
        install -m 644 "$backup/timer" "$BESZEL_HUB_ONEDRIVE_TIMER" || return 1
    else
        rm -f -- "$BESZEL_HUB_ONEDRIVE_TIMER" || return 1
    fi
}

hub_onedrive_schedule_enable() {
    local parsed remote path config time timezone staging backup
    local config_had=no service_had=no timer_had=no timer_unit previous_enabled=no previous_active=no
    vps_require_root || return $?
    hub_check || return $?
    command -v rclone >/dev/null 2>&1 || { printf '缺少必要命令: rclone\n' >&2; return 20; }
    parsed=$(hub_parse_schedule_args "$@") || return $?
    IFS=$'\t' read -r remote path config time timezone <<< "$parsed"
    hub_onedrive_remote_valid "$config" "$remote" || return $?
    if ! hub_path_safe "$BESZEL_HUB_ONEDRIVE_CONFIG" || \
        ! hub_path_safe "$BESZEL_HUB_ONEDRIVE_SERVICE" || \
        ! hub_path_safe "$BESZEL_HUB_ONEDRIVE_TIMER" || \
        ! hub_path_safe "$BESZEL_HUB_VPS_COMMAND" || \
        [[ "$BESZEL_HUB_VPS_COMMAND" =~ [[:space:]] ]]; then
        printf 'vps 命令路径必须是不含空白字符的安全绝对路径。\n' >&2
        return 30
    fi
    [[ -x "$BESZEL_HUB_VPS_COMMAND" && ! -d "$BESZEL_HUB_VPS_COMMAND" ]] || {
        printf '未找到可执行的 vps 命令: %s\n' "$BESZEL_HUB_VPS_COMMAND" >&2
        return 30
    }
    hub_schedule_file_owned_or_absent "$BESZEL_HUB_ONEDRIVE_CONFIG" || return $?
    hub_schedule_file_owned_or_absent "$BESZEL_HUB_ONEDRIVE_SERVICE" || return $?
    hub_schedule_file_owned_or_absent "$BESZEL_HUB_ONEDRIVE_TIMER" || return $?

    staging=$(mktemp -d) || return 40
    backup=$(mktemp -d) || { rm -rf -- "$staging"; return 40; }
    hub_schedule_render "$staging" "$remote" "$path" "$config" "$time" "$timezone" || {
        rm -rf -- "$staging" "$backup"
        return 40
    }
    if [[ -e "$BESZEL_HUB_ONEDRIVE_CONFIG" ]]; then
        config_had=yes
        cp -p "$BESZEL_HUB_ONEDRIVE_CONFIG" "$backup/config" || {
            rm -rf -- "$staging" "$backup"
            return 40
        }
    fi
    if [[ -e "$BESZEL_HUB_ONEDRIVE_SERVICE" ]]; then
        service_had=yes
        cp -p "$BESZEL_HUB_ONEDRIVE_SERVICE" "$backup/service" || {
            rm -rf -- "$staging" "$backup"
            return 40
        }
    fi
    if [[ -e "$BESZEL_HUB_ONEDRIVE_TIMER" ]]; then
        timer_had=yes
        cp -p "$BESZEL_HUB_ONEDRIVE_TIMER" "$backup/timer" || {
            rm -rf -- "$staging" "$backup"
            return 40
        }
    fi
    timer_unit=$(hub_schedule_unit_name "$BESZEL_HUB_ONEDRIVE_TIMER")
    systemctl is-enabled --quiet "$timer_unit" 2>/dev/null && previous_enabled=yes
    systemctl is-active --quiet "$timer_unit" 2>/dev/null && previous_active=yes

    install -d -m 700 "$(dirname -- "$BESZEL_HUB_ONEDRIVE_CONFIG")" || {
        rm -rf -- "$staging" "$backup"
        return 40
    }
    if ! install -m 600 "$staging/config" "$BESZEL_HUB_ONEDRIVE_CONFIG" || \
       ! install -m 644 "$staging/service" "$BESZEL_HUB_ONEDRIVE_SERVICE" || \
       ! install -m 644 "$staging/timer" "$BESZEL_HUB_ONEDRIVE_TIMER" || \
       ! systemctl daemon-reload || \
       ! systemctl enable --now "$timer_unit" || \
       ! systemctl is-enabled --quiet "$timer_unit" || \
       ! systemctl is-active --quiet "$timer_unit"; then
        systemctl disable --now "$timer_unit" >/dev/null 2>&1 || true
        hub_schedule_restore_files "$backup" "$config_had" "$service_had" "$timer_had" || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [[ "$previous_enabled" == yes ]]; then
            systemctl enable "$timer_unit" >/dev/null 2>&1 || true
        fi
        if [[ "$previous_active" == yes ]]; then
            systemctl start "$timer_unit" >/dev/null 2>&1 || true
        fi
        rm -rf -- "$staging" "$backup"
        printf 'OneDrive 定时备份启用失败；已尝试恢复原定时状态。\n' >&2
        return 40
    fi
    rm -rf -- "$staging" "$backup"
    printf 'OneDrive 定时备份已启用。\n'
    printf '每日时间: %s (%s)，另有最多 10 分钟随机延迟。\n' "$time" "$timezone"
    printf '不会自动删除本地或云端备份。\n'
}

hub_schedule_setting() {
    local key=$1
    [[ -f "$BESZEL_HUB_ONEDRIVE_CONFIG" && ! -L "$BESZEL_HUB_ONEDRIVE_CONFIG" ]] || return 1
    sed -n "s/^$key=//p" "$BESZEL_HUB_ONEDRIVE_CONFIG" | head -n 1
}

hub_verified_field() {
    local marker=$1 key=$2
    sed -n "s/^$key=//p" "$marker" | head -n 1
}

hub_retention_preview() {
    local remote path config days minimum parsed cloud_listing marker name digest saved_digest
    local modified cutoff total=0 eligible=0 archive cloud_file
    local verified=()
    vps_require_root || return $?
    hub_schedule_file_owned_or_absent "$BESZEL_HUB_ONEDRIVE_CONFIG" || return $?
    [[ -f "$BESZEL_HUB_ONEDRIVE_CONFIG" ]] || return 30
    remote=$(hub_schedule_setting remote) || return 30
    path=$(hub_schedule_setting path) || return 30
    config=$(hub_schedule_setting rclone_config) || return 30
    days=$(hub_schedule_setting retention_days) || return 30
    minimum=$(hub_schedule_setting retention_min_copies) || return 30
    [[ "$days" =~ ^[0-9]+$ && "$minimum" =~ ^[0-9]+$ ]] || return 30
    (( days >= 1 && days <= 3650 && minimum >= 1 && minimum <= 1000 )) || return 30
    parsed=$(hub_parse_onedrive_args --remote "$remote" --path "$path" --config "$config") || return $?
    IFS=$'\t' read -r remote path config <<< "$parsed"
    hub_onedrive_remote_valid "$config" "$remote" || return $?
    cloud_listing=$(rclone --config "$config" lsf "$remote:$path" --files-only) || {
        printf '无法读取加密云端备份目录；保留策略停止。\n' >&2
        return 40
    }
    cutoff=$(( $(date +%s) - days * 86400 ))
    if [[ -d "$BESZEL_HUB_VERIFIED_DIR" && ! -L "$BESZEL_HUB_VERIFIED_DIR" ]]; then
        for marker in "$BESZEL_HUB_VERIFIED_DIR"/*.verified; do
            [[ -e "$marker" ]] || continue
            [[ -f "$marker" && ! -L "$marker" ]] || return 30
            name=${marker##*/}
            name=${name%.verified}
            [[ "$name" =~ ^beszel-hub-onedrive-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\.tar\.gz$ ]] || return 30
            [[ $(hub_verified_field "$marker" archive) == "$name" ]] || return 30
            [[ $(hub_verified_field "$marker" remote) == "$remote" && \
               $(hub_verified_field "$marker" path) == "$path" ]] || continue
            archive="$BESZEL_HUB_BACKUP_DIR/$name"
            [[ -f "$archive" && ! -L "$archive" && -f "$archive.sha256" && ! -L "$archive.sha256" ]] || return 30
            saved_digest=$(hub_verified_field "$marker" sha256)
            digest=$(sha256sum "$archive" | awk '{print $1}') || return 40
            [[ "$saved_digest" == "$digest" ]] || return 50
            for cloud_file in "$name" "$name.sha256"; do
                grep -Fxq -- "$cloud_file" <<< "$cloud_listing" || {
                    printf '已验证备份在云端缺少文件；保留策略停止。\n' >&2
                    return 50
                }
            done
            verified+=("$marker")
        done
    fi
    total=${#verified[@]}
    for marker in "${verified[@]}"; do
        modified=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker") || return 40
        if (( modified < cutoff && total - eligible > minimum )); then
            eligible=$((eligible + 1))
        fi
    done
    printf '保留策略预览: %s 天，至少保留 %s 份已验证备份。\n' "$days" "$minimum"
    printf '当前目录已验证: %s 份；达到过期条件: %s 份。\n' "$total" "$eligible"
    printf '此操作没有删除本地或云端文件。\n'
}

hub_schedule_result_write() {
    local result=$1 rc=$2 directory temporary
    hub_path_safe "$BESZEL_HUB_BACKUP_RESULT" || return 40
    [[ ! -L "$BESZEL_HUB_BACKUP_RESULT" ]] || return 40
    directory=$(dirname -- "$BESZEL_HUB_BACKUP_RESULT")
    install -d -m 700 "$directory" || return 40
    temporary=$(mktemp "$directory/.onedrive-result.XXXXXX") || return 40
    if ! printf 'result=%s\nexit_code=%s\ncompleted_utc=%s\n' \
        "$result" "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$temporary" || \
       ! chmod 600 "$temporary" || \
       ! mv -- "$temporary" "$BESZEL_HUB_BACKUP_RESULT"; then
        rm -f -- "$temporary"
        return 40
    fi
}

hub_onedrive_scheduled_execute() {
    local remote path config parsed
    hub_schedule_file_owned_or_absent "$BESZEL_HUB_ONEDRIVE_CONFIG" || return $?
    [[ -f "$BESZEL_HUB_ONEDRIVE_CONFIG" ]] || {
        printf '定时备份配置不存在。\n' >&2
        return 30
    }
    remote=$(hub_schedule_setting remote) || return 30
    path=$(hub_schedule_setting path) || return 30
    config=$(hub_schedule_setting rclone_config) || return 30
    parsed=$(hub_parse_onedrive_args --remote "$remote" --path "$path" --config "$config") || return $?
    IFS=$'\t' read -r remote path config <<< "$parsed"
    hub_onedrive_roundtrip --remote "$remote" --path "$path" --config "$config"
}

hub_onedrive_scheduled_run() {
    local rc=0
    vps_require_root || return $?
    if hub_onedrive_scheduled_execute "$@"; then
        hub_schedule_result_write success 0 || return $?
        return 0
    else
        rc=$?
    fi
    hub_schedule_result_write failure "$rc" || {
        printf '备份失败，且无法记录失败状态。\n' >&2
        return 60
    }
    return "$rc"
}

# This is deliberately independent of the oneshot backup unit. Beszel does not
# reliably collect oneshot units that have no ActiveEnterTimestamp, so a
# long-running watchdog can provide a real failed-service alert instead.
hub_backup_health_check() {
    local result_file=$BESZEL_HUB_BACKUP_RESULT timer_unit service_unit
    local max_age=${VPS_BESZEL_BACKUP_MAX_AGE_SECONDS:-100800}
    local modified now result line lines=()
    timer_unit=$(hub_schedule_unit_name "$BESZEL_HUB_ONEDRIVE_TIMER")
    service_unit=$(hub_schedule_unit_name "$BESZEL_HUB_ONEDRIVE_SERVICE")
    [[ "$max_age" =~ ^[0-9]+$ ]] && (( max_age >= 3600 && max_age <= 604800 )) || return 64
    hub_path_safe "$result_file" || return 30
    [[ -f "$result_file" && ! -L "$result_file" ]] || {
        printf '未找到可信的备份结果文件。\n' >&2
        return 40
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        lines+=("$line")
        (( ${#lines[@]} <= 3 )) || break
    done < "$result_file"
    [[ ${#lines[@]} -eq 3 && ${lines[0]} == result=success && \
       ${lines[1]} == exit_code=0 && \
       ${lines[2]} =~ ^completed_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
        printf '最近一次备份未成功或结果文件无效。\n' >&2
        return 40
    }
    modified=$(stat -c %Y "$result_file" 2>/dev/null || stat -f %m "$result_file") || return 40
    now=$(date +%s) || return 40
    (( modified <= now + 300 && now - modified <= max_age )) || {
        printf '最近一次成功备份已过期。\n' >&2
        return 40
    }
    if ! systemctl is-enabled --quiet "$timer_unit" || \
       ! systemctl is-active --quiet "$timer_unit"; then
        printf '备份定时器未启用或未运行。\n' >&2
        return 40
    fi
    result=$(systemctl show "$service_unit" -p Result --value 2>/dev/null) || return 40
    [[ "$result" == success ]] || {
        printf '最近一次备份服务未成功。\n' >&2
        return 40
    }
}

hub_backup_watchdog() {
    local interval=${VPS_BESZEL_BACKUP_WATCH_INTERVAL_SECONDS:-300}
    [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 && interval <= 3600 )) || return 64
    while :; do
        hub_backup_health_check || return $?
        sleep "$interval" || return $?
    done
}

hub_onedrive_schedule_status() {
    local timer_unit state enabled next result value
    timer_unit=$(hub_schedule_unit_name "$BESZEL_HUB_ONEDRIVE_TIMER")
    if [[ ! -f "$BESZEL_HUB_ONEDRIVE_CONFIG" || -L "$BESZEL_HUB_ONEDRIVE_CONFIG" ]]; then
        printf 'OneDrive 定时备份: 未配置\n'
        return 0
    fi
    hub_schedule_file_owned_or_absent "$BESZEL_HUB_ONEDRIVE_CONFIG" || return $?
    for value in remote path time timezone; do
        printf '%s: ' "$value"
        sed -n "s/^$value=//p" "$BESZEL_HUB_ONEDRIVE_CONFIG" | head -n 1
    done
    enabled=$(systemctl is-enabled "$timer_unit" 2>/dev/null || true)
    state=$(systemctl is-active "$timer_unit" 2>/dev/null || true)
    next=$(systemctl show "$timer_unit" -p NextElapseUSecRealtime --value 2>/dev/null || true)
    result=$(systemctl show "$(hub_schedule_unit_name "$BESZEL_HUB_ONEDRIVE_SERVICE")" -p Result --value 2>/dev/null || true)
    printf '定时器启用: %s\n' "${enabled:-unknown}"
    printf '定时器状态: %s\n' "${state:-unknown}"
    printf '下次运行: %s\n' "${next:-尚未计算}"
    printf '上次服务结果: %s\n' "${result:-尚无记录}"
    if [[ -f "$BESZEL_HUB_BACKUP_RESULT" && ! -L "$BESZEL_HUB_BACKUP_RESULT" ]]; then
        for value in result exit_code completed_utc; do
            printf '上次备份 %s: ' "$value"
            sed -n "s/^$value=//p" "$BESZEL_HUB_BACKUP_RESULT" | head -n 1
        done
    fi
}

hub_onedrive_schedule_disable() {
    local timer_unit
    vps_require_root || return $?
    timer_unit=$(hub_schedule_unit_name "$BESZEL_HUB_ONEDRIVE_TIMER")
    hub_schedule_file_owned_or_absent "$BESZEL_HUB_ONEDRIVE_CONFIG" || return $?
    hub_schedule_file_owned_or_absent "$BESZEL_HUB_ONEDRIVE_SERVICE" || return $?
    hub_schedule_file_owned_or_absent "$BESZEL_HUB_ONEDRIVE_TIMER" || return $?
    if ! systemctl is-enabled --quiet "$timer_unit" 2>/dev/null && \
       ! systemctl is-active --quiet "$timer_unit" 2>/dev/null; then
        printf 'OneDrive 定时备份已经停用；配置和已有备份保持不变。\n'
        return 10
    fi
    if ! systemctl disable --now "$timer_unit" || systemctl is-active --quiet "$timer_unit"; then
        systemctl enable --now "$timer_unit" >/dev/null 2>&1 || true
        printf '无法确认定时器已停用；已尝试恢复启用状态。\n' >&2
        return 40
    fi
    printf 'OneDrive 定时备份已停用；配置和已有备份保持不变。\n'
}

hub_main() {
    local action=${1:-}
    shift || true
    case "$action" in
        check) hub_check ;;
        plan) hub_plan ;;
        status) hub_status ;;
        doctor)
            if [[ ${1:-} == onedrive-schedule ]]; then
                hub_onedrive_schedule_status
            elif [[ ${1:-} == onedrive-retention ]]; then
                hub_retention_preview
            elif [[ ${1:-} == onedrive-health ]]; then
                hub_backup_health_check
            else
                hub_status
            fi
            ;;
        watchdog) hub_backup_watchdog ;;
        verify) hub_verify ;;
        backup) hub_backup "$@" ;;
        apply) hub_restore "$@" ;;
        configure)
            if [[ ${1:-} == --scheduled ]]; then
                shift
                hub_onedrive_scheduled_run "$@"
            else
                hub_onedrive_roundtrip "$@"
            fi
            ;;
        start) hub_onedrive_schedule_enable "$@" ;;
        stop) hub_onedrive_schedule_disable ;;
        *) printf 'applications.beszel-hub 不支持操作: %s\n' "$action" >&2; return 64 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    hub_main "$@"
fi
