#!/usr/bin/env bash

set -u

# Keep this assignment simple: VPS Secure 1.x extracts it from the raw file to
# discover that a replacement is available.
VERSION_TAG="v1.0.3"

MIGRATION_TARGET_VERSION=${VPS_MIGRATION_TARGET_VERSION:-2.0.0-beta.4}
MIGRATION_REPOSITORY=${VPS_MIGRATION_REPOSITORY:-playfulsoul/vps-secure-script}
MIGRATION_RELEASE_BASE=${VPS_MIGRATION_RELEASE_BASE:-https://github.com/$MIGRATION_REPOSITORY/releases/download/v$MIGRATION_TARGET_VERSION}
MIGRATION_LINK_PATH=${VPS_MIGRATION_LINK_PATH:-/usr/local/bin/vps}
MIGRATION_INSTALLED_ROOT=${VPS_MIGRATION_INSTALLED_ROOT:-/usr/lib/vps-secure}

migration_header() {
    printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    printf '       VPS Secure 1.x 迁移助手 %s\n' "$VERSION_TAG"
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
}

migration_notice() {
    migration_header
    printf 'VPS Secure 1.x 单文件版本已经停止功能更新。\n'
    printf '2.x 使用新的模块化结构，不能通过覆盖单个脚本完成升级。\n\n'
    printf '推荐操作：移除 1.x 管理入口并重新安装 VPS Secure %s。\n\n' \
        "$MIGRATION_TARGET_VERSION"
    printf '此操作只替换 VPS Secure 管理程序，不会：\n'
    printf '  - 修改现有 SSH 端口或登录方式；\n'
    printf '  - 删除 UFW、Fail2Ban、BBR、Swap 或应用配置；\n'
    printf '  - 重新执行服务器安全初始化。\n\n'
    if [[ "$MIGRATION_TARGET_VERSION" == *-* ]]; then
        printf '提示：目标版本目前仍是 Beta 测试版。\n\n'
    fi
}

migration_require_root() {
    if (( EUID != 0 )) && [[ ${VPS_MIGRATION_ALLOW_NON_ROOT:-no} != yes ]]; then
        printf '重新安装 VPS Secure 需要 root 权限，请使用 sudo。\n' >&2
        return 30
    fi
}

migration_platform_check() {
    local os_release=${VPS_MIGRATION_OS_RELEASE_FILE:-/etc/os-release}
    local platform version major
    [[ ${VPS_MIGRATION_SKIP_PLATFORM_CHECK:-no} == yes ]] && return 0
    [[ -r "$os_release" ]] || {
        printf '无法识别当前系统，2.x 尚未安装。\n' >&2
        return 20
    }
    platform=$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2; exit }' "$os_release")
    version=$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2; exit }' "$os_release")
    major=${version%%.*}
    [[ "$major" =~ ^[0-9]+$ ]] || major=0
    case "$platform" in
        debian) (( major >= 11 )) && return 0 ;;
        ubuntu) (( major >= 22 )) && return 0 ;;
    esac
    printf 'VPS Secure 2.x 当前支持 Debian 11+ 和 Ubuntu 22.04+。\n' >&2
    printf '检测到的系统：%s %s；迁移已停止，服务器配置没有改变。\n' \
        "${platform:-unknown}" "${version:-unknown}" >&2
    return 20
}

migration_sha256() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{ print $1 }'
    else
        printf '系统缺少 SHA-256 校验工具。\n' >&2
        return 20
    fi
}

migration_existing_v2_check() {
    if [[ -r "$MIGRATION_INSTALLED_ROOT/VERSION" ]]; then
        printf '检测到 VPS Secure %s 已经安装。\n' "$(<"$MIGRATION_INSTALLED_ROOT/VERSION")"
        printf '请直接输入 vps，并在“程序更新与恢复”中管理后续版本。\n'
        return 0
    fi
    return 1
}

migration_archive_is_safe() {
    local archive=$1 entry type

    while IFS= read -r entry; do
        case "$entry" in
            /*|../*|*/../*|*/..)
                printf '安装包包含不安全路径，已拒绝安装：%s\n' "$entry" >&2
                return 40
                ;;
        esac
    done < <(tar -tzf "$archive") || return 40

    while IFS= read -r type; do
        case "$type" in
            l|h)
                printf '安装包包含链接文件，已拒绝安装。\n' >&2
                return 40
                ;;
        esac
    done < <(tar -tvzf "$archive" | awk '{ print substr($1, 1, 1) }') || return 40
}

migration_download() {
    local url=$1 destination=$2
    curl --fail --location --proto '=https' --tlsv1.2 \
        --connect-timeout 5 --max-time 120 \
        "$url" -o "$destination"
}

migration_prepare_regular_link() {
    local backup_variable=$1 timestamp backup=''
    if [[ -e "$MIGRATION_LINK_PATH" && ! -L "$MIGRATION_LINK_PATH" ]]; then
        timestamp=$(date -u +%Y%m%dT%H%M%SZ)
        backup="$MIGRATION_LINK_PATH.legacy.$timestamp"
        mv -- "$MIGRATION_LINK_PATH" "$backup" || return 40
        printf -v "$backup_variable" '%s' "$backup"
        printf '旧版普通文件入口已备份到：%s\n' "$backup"
    fi
}

migration_restore_regular_link() {
    local backup=$1
    [[ -n "$backup" && -e "$backup" ]] || return 0
    rm -f -- "$MIGRATION_LINK_PATH"
    mv -- "$backup" "$MIGRATION_LINK_PATH"
}

migration_install() {
    local archive_name work_dir archive checksum_file extract_dir
    local expected actual legacy_link_backup=''

    migration_require_root || return $?
    migration_platform_check || return $?
    if migration_existing_v2_check; then
        return 10
    fi
    command -v curl >/dev/null 2>&1 || {
        printf '安装需要 curl，请先安装 curl。\n' >&2
        return 20
    }
    command -v tar >/dev/null 2>&1 || {
        printf '安装需要 tar。\n' >&2
        return 20
    }

    archive_name="vps-secure-platform-$MIGRATION_TARGET_VERSION.tar.gz"
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-secure-migration.XXXXXX") || return 40
    archive="$work_dir/$archive_name"
    checksum_file="$archive.sha256"
    extract_dir="$work_dir/source"
    mkdir -p "$extract_dir" || { rm -rf -- "$work_dir"; return 40; }

    printf '正在下载 VPS Secure %s 完整安装包……\n' "$MIGRATION_TARGET_VERSION"
    if ! migration_download "$MIGRATION_RELEASE_BASE/$archive_name" "$archive" ||
       ! migration_download "$MIGRATION_RELEASE_BASE/$archive_name.sha256" "$checksum_file"; then
        rm -rf -- "$work_dir"
        printf '下载失败，当前管理入口没有被修改。\n' >&2
        return 40
    fi

    expected=$(awk 'NR == 1 { print $1 }' "$checksum_file")
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || {
        rm -rf -- "$work_dir"
        printf '校验文件格式无效，已拒绝安装。\n' >&2
        return 40
    }
    actual=$(migration_sha256 "$archive") || { rm -rf -- "$work_dir"; return 40; }
    if [[ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" != \
          "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]]; then
        rm -rf -- "$work_dir"
        printf '安装包 SHA-256 校验失败，已拒绝安装。\n' >&2
        return 40
    fi
    migration_archive_is_safe "$archive" || { rm -rf -- "$work_dir"; return 40; }
    tar -xzf "$archive" -C "$extract_dir" || { rm -rf -- "$work_dir"; return 40; }
    [[ -x "$extract_dir/install.sh" && -r "$extract_dir/VERSION" ]] || {
        rm -rf -- "$work_dir"
        printf '安装包结构不完整，已拒绝安装。\n' >&2
        return 40
    }
    [[ "$(<"$extract_dir/VERSION")" == "$MIGRATION_TARGET_VERSION" ]] || {
        rm -rf -- "$work_dir"
        printf '安装包版本与目标版本不一致，已拒绝安装。\n' >&2
        return 40
    }

    migration_prepare_regular_link legacy_link_backup || { rm -rf -- "$work_dir"; return 40; }
    if ! "$extract_dir/install.sh"; then
        migration_restore_regular_link "$legacy_link_backup" || true
        rm -rf -- "$work_dir"
        printf '2.x 安装失败，已尽力恢复原来的管理入口。\n' >&2
        return 40
    fi
    rm -rf -- "$work_dir"

    printf '\n[完成] VPS Secure %s 已重新安装。\n' "$MIGRATION_TARGET_VERSION"
    printf '以后直接输入 vps 使用新版本；2.x 会自动提示后续更新。\n'
}

migration_manual_help() {
    printf '版本说明：https://github.com/%s/releases/tag/v%s\n' \
        "$MIGRATION_REPOSITORY" "$MIGRATION_TARGET_VERSION"
    printf '如暂不迁移，可退出；现有服务器配置不会受到影响。\n'
}

migration_menu() {
    local choice
    while true; do
        migration_notice
        printf '  1. 移除 1.x 管理入口并安装 2.x（推荐）\n'
        printf '  2. 查看版本和手动安装说明\n'
        printf '  0. 暂不处理\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1)
                migration_install
                printf '\n按回车键继续……'
                read -r _
                return
                ;;
            2)
                migration_manual_help
                printf '\n按回车键继续……'
                read -r _
                ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

case ${1:-} in
    --version|version)
        printf 'vps-secure legacy migration %s -> %s\n' "$VERSION_TAG" "$MIGRATION_TARGET_VERSION"
        ;;
    --install)
        [[ ${2:-} == --yes ]] || {
            migration_notice
            printf '确认后请使用：sudo bash vps_secure.sh --install --yes\n' >&2
            exit 64
        }
        migration_install
        ;;
    '') migration_menu ;;
    *)
        printf '用法：bash vps_secure.sh [--version|--install --yes]\n' >&2
        exit 64
        ;;
esac
