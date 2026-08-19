#!/usr/bin/env bash

vps_require_apt() {
    command -v apt-get >/dev/null 2>&1 || {
        printf '当前模块需要 APT。\n' >&2
        return 20
    }
}

vps_apt_locks_available() {
    local lock
    for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
        if command -v fuser >/dev/null 2>&1 && fuser "$lock" >/dev/null 2>&1; then
            printf 'APT/dpkg 正被其他进程占用: %s\n' "$lock" >&2
            return 1
        fi
    done
}

vps_apt_update() {
    vps_require_apt || return $?
    vps_apt_locks_available || return 30
    DEBIAN_FRONTEND=noninteractive apt-get update
}

vps_apt_install() {
    vps_require_apt || return $?
    vps_apt_locks_available || return 30
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}
