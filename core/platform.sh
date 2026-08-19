#!/usr/bin/env bash

vps_os_release_file() {
    printf '%s\n' "${VPS_OS_RELEASE_FILE:-/etc/os-release}"
}

vps_os_release_value() {
    local key=$1
    local file=${2:-$(vps_os_release_file)}
    local line value

    [[ -r "$file" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] || continue
        value=${line#*=}
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
            value=${value:1:${#value}-2}
        elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
            value=${value:1:${#value}-2}
        fi
        printf '%s\n' "$value"
        return 0
    done < "$file"

    return 1
}

vps_platform_id() {
    vps_os_release_value ID
}

vps_platform_version() {
    vps_os_release_value VERSION_ID
}

vps_platform_label() {
    local platform version
    platform=$(vps_platform_id 2>/dev/null || printf 'unknown')
    version=$(vps_platform_version 2>/dev/null || printf 'unknown')
    printf '%s %s\n' "$platform" "$version"
}

vps_has_systemd() {
    local runtime_dir=${VPS_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}
    command -v systemctl >/dev/null 2>&1 && [[ -d "$runtime_dir" ]]
}

vps_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf 'apt\n'
    elif command -v dnf >/dev/null 2>&1; then
        printf 'dnf\n'
    elif command -v yum >/dev/null 2>&1; then
        printf 'yum\n'
    else
        return 1
    fi
}
