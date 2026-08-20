#!/usr/bin/env bash

VPS_UPDATE_REPOSITORY=${VPS_UPDATE_REPOSITORY:-playfulsoul/vps-secure-script}
VPS_UPDATE_CACHE_TTL=${VPS_UPDATE_CACHE_TTL:-86400}

vps_update_channel() {
    if [[ -n "${VPS_UPDATE_CHANNEL:-}" ]]; then
        printf '%s\n' "$VPS_UPDATE_CHANNEL"
    elif [[ ${VERSION:-} == *-* ]]; then
        printf 'beta\n'
    else
        printf 'stable\n'
    fi
}

vps_version_is_newer() {
    local candidate=${1#v} current=${2#v}
    local candidate_core=${candidate%%-*} current_core=${current%%-*}
    local candidate_pre='' current_pre=''
    local candidate_parts=() current_parts=()
    local index candidate_number current_number

    [[ "$candidate" == *-* ]] && candidate_pre=${candidate#*-}
    [[ "$current" == *-* ]] && current_pre=${current#*-}
    IFS=. read -r -a candidate_parts <<< "$candidate_core"
    IFS=. read -r -a current_parts <<< "$current_core"

    for index in 0 1 2; do
        candidate_number=${candidate_parts[index]:-0}
        current_number=${current_parts[index]:-0}
        (( 10#$candidate_number > 10#$current_number )) && return 0
        (( 10#$candidate_number < 10#$current_number )) && return 1
    done

    [[ -z "$candidate_pre" && -n "$current_pre" ]] && return 0
    [[ -n "$candidate_pre" && -z "$current_pre" ]] && return 1
    [[ "$candidate_pre" == "$current_pre" ]] && return 1

    [[ "$(printf '%s\n%s\n' "$current_pre" "$candidate_pre" | sort -V | tail -n 1)" == "$candidate_pre" ]]
}

vps_update_api_url() {
    local channel
    channel=$(vps_update_channel)
    if [[ -n "${VPS_UPDATE_API_URL:-}" ]]; then
        printf '%s\n' "$VPS_UPDATE_API_URL"
    elif [[ "$channel" == stable ]]; then
        printf 'https://api.github.com/repos/%s/releases/latest\n' "$VPS_UPDATE_REPOSITORY"
    else
        printf 'https://api.github.com/repos/%s/releases?per_page=20\n' "$VPS_UPDATE_REPOSITORY"
    fi
}

vps_update_cache_dir() {
    if [[ -n "${VPS_UPDATE_CACHE_DIR:-}" ]]; then
        printf '%s\n' "$VPS_UPDATE_CACHE_DIR"
    elif (( EUID == 0 )); then
        printf '/var/cache/vps-secure/update\n'
    else
        printf '%s/vps-secure/update\n' "${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}"
    fi
}

vps_update_extract_version() {
    local response_file=$1 tag candidate latest=''
    while IFS= read -r candidate; do
        candidate=${candidate#v}
        [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || continue
        if [[ -z "$latest" ]] || vps_version_is_newer "$candidate" "$latest"; then
            latest=$candidate
        fi
    done < <(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' "$response_file" 2>/dev/null |
        sed -E 's/.*"([^"]+)"$/\1/')
    tag=$latest
    [[ -n "$tag" ]] || return 1
    printf '%s\n' "$tag"
}

vps_update_fetch_version() {
    local force=${1:-no} cache_dir response_file now modified
    cache_dir=$(vps_update_cache_dir)
    response_file="$cache_dir/release.json"
    now=$(date +%s)

    if [[ "$force" != yes && -r "$response_file" ]]; then
        modified=$(stat -c %Y "$response_file" 2>/dev/null || stat -f %m "$response_file" 2>/dev/null || printf '0')
        if [[ "$modified" =~ ^[0-9]+$ ]] && (( now - modified < VPS_UPDATE_CACHE_TTL )); then
            vps_update_extract_version "$response_file"
            return
        fi
    fi

    command -v curl >/dev/null 2>&1 || return 10
    mkdir -p "$cache_dir" 2>/dev/null || return 10
    if ! curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --connect-timeout 2 --max-time 5 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2026-03-10' \
        "$(vps_update_api_url)" -o "$response_file.tmp.$$"; then
        rm -f "$response_file.tmp.$$"
        return 10
    fi
    mv "$response_file.tmp.$$" "$response_file" || return 10
    vps_update_extract_version "$response_file"
}

vps_update_check() {
    local force=${1:-yes} latest
    latest=$(vps_update_fetch_version "$force") || {
        printf '暂时无法连接 GitHub 检查更新；不影响现有功能。\n' >&2
        return 10
    }
    if vps_version_is_newer "$latest" "$VERSION"; then
        printf '发现新版本: %s（当前版本: %s，通道: %s）\n' \
            "$latest" "$VERSION" "$(vps_update_channel)"
        printf '更新说明: https://github.com/%s/releases/tag/v%s\n' \
            "$VPS_UPDATE_REPOSITORY" "$latest"
        return 20
    fi
    printf '当前已是所选通道的最新版本: %s\n' "$VERSION"
}

vps_update_notice() {
    local latest
    [[ -t 0 && -t 1 ]] || return 0
    latest=$(vps_update_fetch_version no 2>/dev/null) || return 0
    if vps_version_is_newer "$latest" "$VERSION"; then
        printf '\n[更新] 发现新版本 %s，当前为 %s。可在主菜单选择“更新与恢复”。\n' \
            "$latest" "$VERSION"
        VPS_UPDATE_AVAILABLE=$latest
        export VPS_UPDATE_AVAILABLE
    fi
}

vps_update_apply() {
    local latest archive_name base_url temporary_dir checksum_file archive expected actual extract_dir
    (( EUID == 0 )) || {
        printf '安装平台更新需要 root 权限，请使用 sudo vps update apply --yes。\n' >&2
        return 30
    }
    command -v curl >/dev/null 2>&1 || { printf '更新需要 curl。\n' >&2; return 20; }

    latest=$(vps_update_fetch_version yes) || return 10
    if ! vps_version_is_newer "$latest" "$VERSION"; then
        printf '当前已是所选通道的最新版本: %s\n' "$VERSION"
        return 0
    fi

    archive_name="vps-secure-platform-$latest.tar.gz"
    base_url="https://github.com/$VPS_UPDATE_REPOSITORY/releases/download/v$latest"
    temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-secure-update.XXXXXX") || return 40
    archive="$temporary_dir/$archive_name"
    checksum_file="$archive.sha256"
    extract_dir="$temporary_dir/source"
    mkdir -p "$extract_dir" || { rm -rf -- "$temporary_dir"; return 40; }

    printf '正在下载并校验 VPS Secure %s……\n' "$latest"
    if ! curl --proto '=https' --tlsv1.2 --fail --location --show-error \
        --connect-timeout 5 --max-time 120 "$base_url/$archive_name" -o "$archive" || \
       ! curl --proto '=https' --tlsv1.2 --fail --location --show-error \
        --connect-timeout 5 --max-time 30 "$base_url/$archive_name.sha256" -o "$checksum_file"; then
        rm -rf -- "$temporary_dir"
        printf '更新文件下载失败，现有版本未改变。\n' >&2
        return 40
    fi

    expected=$(awk 'NR == 1 { print $1 }' "$checksum_file")
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || { rm -rf -- "$temporary_dir"; return 40; }
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$archive" | awk '{ print $1 }')
    else
        actual=$(shasum -a 256 "$archive" | awk '{ print $1 }')
    fi
    [[ "${actual,,}" == "${expected,,}" ]] || {
        rm -rf -- "$temporary_dir"
        printf '更新包校验失败，已拒绝安装。\n' >&2
        return 40
    }

    tar -xzf "$archive" -C "$extract_dir" || { rm -rf -- "$temporary_dir"; return 40; }
    [[ -x "$extract_dir/install.sh" && -r "$extract_dir/VERSION" ]] || {
        rm -rf -- "$temporary_dir"
        printf '更新包结构无效，已拒绝安装。\n' >&2
        return 40
    }
    [[ "$(<"$extract_dir/VERSION")" == "$latest" ]] || {
        rm -rf -- "$temporary_dir"
        printf '更新包版本与发布信息不一致。\n' >&2
        return 40
    }

    if ! "$extract_dir/install.sh"; then
        rm -rf -- "$temporary_dir"
        printf '更新安装失败；安装器已尽力保留上一版本备份。\n' >&2
        return 40
    fi
    rm -rf -- "$temporary_dir"
    printf '更新完成。请重新输入 vps 使用新版本。\n'
}

vps_update_backup_list() {
    local install_parent install_name
    install_parent=$(dirname -- "$VPS_PLATFORM_ROOT")
    install_name=$(basename -- "$VPS_PLATFORM_ROOT")
    find "$install_parent" -maxdepth 1 -type d -name "$install_name.backup.*" -print 2>/dev/null | sort -r
}

vps_update_rollback() {
    local previous displaced timestamp
    (( EUID == 0 )) || {
        printf '恢复平台版本需要 root 权限。\n' >&2
        return 30
    }
    previous=$(vps_update_backup_list | head -n 1)
    [[ -n "$previous" ]] || {
        printf '没有找到可恢复的上一版本备份。\n' >&2
        return 60
    }
    [[ -d "$VPS_PLATFORM_ROOT" && -r "$previous/VERSION" ]] || return 60
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    displaced="$VPS_PLATFORM_ROOT.rollback-replaced.$timestamp"
    if ! mv "$VPS_PLATFORM_ROOT" "$displaced"; then return 60; fi
    if ! mv "$previous" "$VPS_PLATFORM_ROOT"; then
        mv "$displaced" "$VPS_PLATFORM_ROOT" 2>/dev/null || true
        return 60
    fi
    printf '已恢复版本 %s。刚才的版本保存在 %s。\n' "$(<"$VPS_PLATFORM_ROOT/VERSION")" "$displaced"
    printf '请重新输入 vps。\n'
}
