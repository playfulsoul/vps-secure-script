#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/packages.sh
source "$VPS_PLATFORM_ROOT/core/packages.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

packages_check() {
    vps_require_apt || return $?
    vps_apt_locks_available || return 30
}

packages_plan() {
    packages_check || return $?
    printf '软件包维护计划：\n'
    printf '  - 更新 APT 软件包索引。\n'
    printf '  - 执行常规 apt-get upgrade，不自动执行发行版升级。\n'
    printf '  - APT/dpkg 被占用时停止，不强行删除锁文件。\n'
}

packages_status() {
    vps_require_apt || return $?
    local count
    count=$(apt-get -s upgrade 2>/dev/null | awk '/^Inst / { count++ } END { print count + 0 }')
    printf '可升级软件包: %s\n' "$count"
}

packages_apply() {
    vps_require_root || return $?
    packages_check || return $?
    vps_apt_update || return 40
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || return 40
    printf '软件包索引和常规升级已完成。\n'
}

case ${1:-} in
    check) packages_check ;;
    plan) packages_plan ;;
    status|doctor) packages_status ;;
    apply) packages_apply ;;
    *) printf 'system.packages 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
