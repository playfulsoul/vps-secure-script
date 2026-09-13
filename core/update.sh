#!/usr/bin/env bash

VPS_UPDATE_REPOSITORY=${VPS_UPDATE_REPOSITORY:-playfulsoul/vps-secure-script}
VPS_UPDATE_CACHE_TTL=${VPS_UPDATE_CACHE_TTL:-86400}
VPS_UPDATE_FAILURE_CACHE_TTL=${VPS_UPDATE_FAILURE_CACHE_TTL:-900}
VPS_UPDATE_DOWNLOAD_ATTEMPTS=${VPS_UPDATE_DOWNLOAD_ATTEMPTS:-4}
VPS_UPDATE_DOWNLOAD_RETRY_DELAY=${VPS_UPDATE_DOWNLOAD_RETRY_DELAY:-2}

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

vps_update_cache_is_fresh() {
    local file=$1 ttl=$2 now=${3:-$(date +%s)} modified
    [[ "$ttl" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
    [[ -r "$file" ]] || return 1
    modified=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || printf '0')
    [[ "$modified" =~ ^[0-9]+$ ]] && (( now - modified < ttl ))
}

vps_update_record_fetch_failure() {
    local cache_dir=$1 marker temporary_marker
    marker="$cache_dir/last-fetch-failure"
    temporary_marker=$(mktemp "$cache_dir/last-fetch-failure.XXXXXX") || return 0
    if ! mv -f -- "$temporary_marker" "$marker"; then
        rm -f -- "$temporary_marker"
    fi
}

vps_update_fetch_metadata() {
    local output=$1 mode=${2:-automatic} attempts=1 max_time=3 attempt status=0
    local deadline remaining now
    [[ "$VPS_UPDATE_DOWNLOAD_RETRY_DELAY" =~ ^[0-9]+$ ]] || return 10
    if [[ "$mode" == explicit ]]; then
        attempts=3
        max_time=30
    fi
    deadline=$(( $(date +%s) + max_time ))

    for (( attempt = 1; attempt <= attempts; attempt++ )); do
        now=$(date +%s)
        remaining=$(( deadline - now ))
        (( remaining > 0 )) || break
        if curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
            --connect-timeout 5 --max-time "$remaining" \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2026-03-10' \
            "$(vps_update_api_url)" -o "$output"; then
            return 0
        else
            status=$?
        fi
        now=$(date +%s)
        if (( attempt < attempts && now + VPS_UPDATE_DOWNLOAD_RETRY_DELAY < deadline )); then
            sleep "$VPS_UPDATE_DOWNLOAD_RETRY_DELAY"
        fi
    done
    (( status != 0 )) || status=28
    return "$status"
}

vps_update_download_asset() {
    local url=$1 destination=$2 max_time=$3 resume=${4:-no}
    local partial="$destination.part" attempt status=0 deadline remaining now

    [[ "$max_time" =~ ^[1-9][0-9]*$ ]] || return 40
    [[ "$VPS_UPDATE_DOWNLOAD_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || return 40
    [[ "$VPS_UPDATE_DOWNLOAD_RETRY_DELAY" =~ ^[0-9]+$ ]] || return 40
    rm -f -- "$partial"
    deadline=$(( $(date +%s) + max_time ))

    for (( attempt = 1; attempt <= VPS_UPDATE_DOWNLOAD_ATTEMPTS; attempt++ )); do
        now=$(date +%s)
        remaining=$(( deadline - now ))
        (( remaining > 0 )) || break
        [[ "$resume" == yes ]] || rm -f -- "$partial"
        local curl_arguments=(
            --proto '=https' --tlsv1.2 --fail --location --show-error
            --connect-timeout 10 --max-time "$remaining"
        )
        [[ "$resume" != yes ]] || curl_arguments+=(--continue-at -)

        if curl "${curl_arguments[@]}" "$url" -o "$partial"; then
            mv -f -- "$partial" "$destination"
            return 0
        else
            status=$?
        fi

        # A server that refuses byte ranges cannot resume this partial file.
        # Discard it once and let the next bounded attempt start cleanly.
        if [[ "$resume" == yes && "$status" -eq 33 ]]; then
            rm -f -- "$partial"
        fi
        now=$(date +%s)
        if (( attempt < VPS_UPDATE_DOWNLOAD_ATTEMPTS && \
              now + VPS_UPDATE_DOWNLOAD_RETRY_DELAY < deadline )); then
            printf '下载中断，将在 %s 秒后重试（%s/%s）……\n' \
                "$VPS_UPDATE_DOWNLOAD_RETRY_DELAY" "$attempt" "$VPS_UPDATE_DOWNLOAD_ATTEMPTS" >&2
            sleep "$VPS_UPDATE_DOWNLOAD_RETRY_DELAY"
        fi
    done

    rm -f -- "$partial"
    (( status != 0 )) || status=28
    return "$status"
}

vps_update_fetch_version() {
    local force=${1:-no} cache_dir response_file failure_marker now temporary_response mode=automatic
    cache_dir=$(vps_update_cache_dir)
    response_file="$cache_dir/release.json"
    failure_marker="$cache_dir/last-fetch-failure"
    now=$(date +%s)

    if [[ "$force" != yes ]]; then
        if vps_update_cache_is_fresh "$response_file" "$VPS_UPDATE_CACHE_TTL" "$now"; then
            vps_update_extract_version "$response_file"
            return
        fi
        # A failed background check must not delay every interactive menu open.
        vps_update_cache_is_fresh "$failure_marker" "$VPS_UPDATE_FAILURE_CACHE_TTL" "$now" && return 10
    else
        mode=explicit
    fi

    command -v curl >/dev/null 2>&1 || return 10
    mkdir -p "$cache_dir" 2>/dev/null || return 10
    chmod 700 "$cache_dir" 2>/dev/null || true
    temporary_response=$(mktemp "$cache_dir/release.json.XXXXXX") || return 10
    if ! vps_update_fetch_metadata "$temporary_response" "$mode" || \
       ! vps_update_extract_version "$temporary_response" >/dev/null; then
        rm -f -- "$temporary_response"
        vps_update_record_fetch_failure "$cache_dir"
        return 10
    fi
    mv -f -- "$temporary_response" "$response_file" || return 10
    rm -f -- "$failure_marker"
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
    local latest archive_name base_url temporary_dir checksum_file archive expected actual extract_dir old_umask
    (( EUID == 0 )) || {
        printf '安装平台更新需要 root 权限，请使用 sudo vps update apply --yes。\n' >&2
        return 30
    }
    command -v curl >/dev/null 2>&1 || { printf '更新需要 curl。\n' >&2; return 20; }

    latest=$(vps_update_fetch_version yes) || {
        printf '暂时无法连接 GitHub 获取更新信息，现有版本未改变。网络恢复后可重新执行更新。\n' >&2
        return 10
    }
    if ! vps_version_is_newer "$latest" "$VERSION"; then
        printf '当前已是所选通道的最新版本: %s\n' "$VERSION"
        return 0
    fi

    archive_name="vps-secure-platform-$latest.tar.gz"
    base_url="https://github.com/$VPS_UPDATE_REPOSITORY/releases/download/v$latest"
    old_umask=$(umask)
    umask 077
    if ! temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-secure-update.XXXXXX"); then
        umask "$old_umask"
        printf '无法创建安全的更新临时目录，现有版本未改变。\n' >&2
        return 40
    fi
    umask "$old_umask"
    archive="$temporary_dir/$archive_name"
    checksum_file="$archive.sha256"
    extract_dir="$temporary_dir/source"
    mkdir -p "$extract_dir" || { rm -rf -- "$temporary_dir"; return 40; }

    printf '正在下载并校验 VPS Secure %s……\n' "$latest"
    if ! vps_update_download_asset "$base_url/$archive_name" "$archive" 300 yes || \
       ! vps_update_download_asset "$base_url/$archive_name.sha256" "$checksum_file" 30 no; then
        rm -rf -- "$temporary_dir"
        printf '更新文件多次下载失败，现有版本未改变。网络恢复后可重新执行更新。\n' >&2
        return 40
    fi

    expected=$(awk 'NR == 1 { print $1 }' "$checksum_file")
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || {
        rm -rf -- "$temporary_dir"
        printf '更新包校验文件无效，已拒绝安装；现有版本未改变。\n' >&2
        return 40
    }
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
