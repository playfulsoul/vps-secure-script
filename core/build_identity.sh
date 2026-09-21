#!/usr/bin/env bash

vps_build_sha256_file() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        printf '缺少 SHA-256 校验工具。\n' >&2
        return 20
    fi
}

vps_build_sha256_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        printf '缺少 SHA-256 校验工具。\n' >&2
        return 20
    fi
}

vps_build_file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

vps_build_manifest() {
    local root=$1 output=$2 path relative mode kind digest target

    root=$(cd -- "$root" && pwd) || return 40
    : > "$output" || return 40
    while IFS= read -r path; do
        relative=${path#"$root"/}
        if [[ "$relative" == *$'\n'* ]]; then
            printf '构建路径不允许包含换行符。\n' >&2
            return 40
        fi
        mode=$(vps_build_file_mode "$path") || return 40
        if [[ -L "$path" ]]; then
            kind='link'
            target=$(readlink "$path") || return 40
            digest=$(printf '%s' "$target" | vps_build_sha256_text) || return 40
        elif [[ -f "$path" ]]; then
            kind='file'
            digest=$(vps_build_sha256_file "$path") || return 40
        else
            kind='directory'
            digest='-'
        fi
        printf '%s %s %s %s\n' "$kind" "$mode" "$digest" "$relative" >> "$output" || return 40
    done < <(find -P "$root" -mindepth 1 \
        \( -name .git -o -name dist -o -name .DS_Store -o \
           -name BUILD_ID -o -name BUILD_MANIFEST.sha256 \) -prune -o \
        \( -type f -o -type d -o -type l \) -print | LC_ALL=C sort)
}

vps_calculate_build_id() {
    local root=$1 manifest digest
    manifest=$(mktemp "${TMPDIR:-/tmp}/vps-build-manifest.XXXXXX") || return 40
    vps_build_manifest "$root" "$manifest" || { rm -f -- "$manifest"; return 40; }
    digest=$(vps_build_sha256_file "$manifest") || { rm -f -- "$manifest"; return 40; }
    rm -f -- "$manifest"
    printf 'sha256-%s\n' "$digest"
}

vps_read_build_id() {
    local root=$1 build_file manifest_file expected actual
    build_file="$root/BUILD_ID"
    if [[ ! -r "$build_file" ]]; then
        vps_calculate_build_id "$root"
        return
    fi

    IFS= read -r expected < "$build_file" || return 40
    [[ "$expected" =~ ^sha256-[a-f0-9]{64}$ ]] || {
        printf '构建身份格式无效。\n' >&2
        return 40
    }
    manifest_file="$root/BUILD_MANIFEST.sha256"
    if [[ -r "$manifest_file" ]]; then
        actual="sha256-$(vps_build_sha256_file "$manifest_file")" || return 40
    else
        actual=$(vps_calculate_build_id "$root") || return 40
    fi
    [[ "$actual" == "$expected" ]] || {
        printf '构建身份与候选内容不一致，已拒绝继续。\n' >&2
        return 40
    }
    printf '%s\n' "$expected"
}

vps_verify_build_identity() {
    local root=$1 expected actual
    expected=$(vps_read_build_id "$root") || return $?
    actual=$(vps_calculate_build_id "$root") || return $?
    [[ "$actual" == "$expected" ]] || {
        printf '构建身份与候选内容不一致，已拒绝继续。\n' >&2
        return 40
    }
    printf '%s\n' "$expected"
}
