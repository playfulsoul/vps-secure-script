#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/installer.sh
source "$VPS_PLATFORM_ROOT/core/installer.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

INSTALL_URL=https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh

panel_check() {
    command -v curl >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 || return 20
}

panel_plan() {
    printf '1Panel v2 执行计划：\n'
    printf '  - 从官方地址下载脚本到临时文件，不通过管道直接执行。\n'
    printf '  - 必须提供事先审查脚本后得到的 SHA-256。\n'
    printf '  - 校验成功后以交互方式运行官方安装器。\n'
    printf '  - 地址: %s\n' "$INSTALL_URL"
}

panel_status() {
    if ! command -v 1pctl >/dev/null 2>&1; then
        printf '1Panel 未安装。\n'
        return 10
    fi
    1pctl status
}

panel_verify() {
    command -v 1pctl >/dev/null 2>&1 || return 50
    1pctl status >/dev/null 2>&1 || return 50
    printf '1Panel 命令和服务状态可用。\n'
}

panel_apply() {
    local expected='' work_dir script actual
    vps_require_root || return $?
    panel_check || return $?
    command -v 1pctl >/dev/null 2>&1 && { printf '1Panel 已安装。\n'; return 10; }
    [[ ${1:-} == --sha256 ]] && expected=${2:-}
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || {
        printf '必须通过 --sha256 提供已审查官方脚本的摘要。\n' >&2
        return 64
    }
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-1panel.XXXXXX") || return 40
    script="$work_dir/quick_start.sh"
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$INSTALL_URL" -o "$script"; then
        rm -rf "$work_dir"
        return 40
    fi
    actual=$(vps_sha256 "$script") || { rm -rf "$work_dir"; return 40; }
    if [[ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" != \
          "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]]; then
        printf '1Panel 安装脚本 SHA-256 不匹配。\n' >&2
        rm -rf "$work_dir"
        return 40
    fi
    bash "$script"
    local result=$?
    rm -rf "$work_dir"
    (( result == 0 )) || return 40
    panel_verify
}

panel_uninstall() {
    vps_require_root || return $?
    command -v 1pctl >/dev/null 2>&1 || return 10
    1pctl uninstall
}

case ${1:-} in
    check) panel_check ;;
    plan) panel_plan ;;
    status|doctor) panel_status ;;
    apply) shift; panel_apply "$@" ;;
    verify) panel_verify ;;
    uninstall) panel_uninstall ;;
    *) printf 'applications.1panel 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
