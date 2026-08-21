#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/installer.sh
source "$VPS_PLATFORM_ROOT/core/installer.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

INSTALL_URL=https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh
INSTALL_SHA256=${VPS_1PANEL_INSTALL_SHA256:-619716796c54a4e3f82c21dff4d7d3e9eb44b7dd1f3fceb90e8e1f584f674d9c}

panel_check() {
    command -v curl >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 || return 20
}

panel_plan() {
    printf '1Panel v2 执行计划：\n'
    printf '  - 从官方地址下载脚本到临时文件，不通过管道直接执行。\n'
    printf '  - 使用平台目录中的 SHA-256 校验入口脚本: %s。\n' "$INSTALL_SHA256"
    printf '  - 校验成功后以交互方式运行官方安装器。\n'
    printf '  - 官方安装器仍会继续下载 1Panel 软件包。\n'
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

panel_fetch_verified() {
    local destination=$1 expected=${2:-$INSTALL_SHA256} actual
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 5 --max-time 120 "$INSTALL_URL" -o "$destination"; then
        return 40
    fi
    actual=$(vps_sha256 "$destination") || return 40
    if [[ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" != \
          "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]]; then
        printf '1Panel 安装脚本 SHA-256 不匹配。\n' >&2
        return 40
    fi
}

panel_preflight() {
    local work_dir script
    panel_check || return $?
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-1panel-preflight.XXXXXX") || return 40
    script="$work_dir/quick_start.sh"
    if ! panel_fetch_verified "$script"; then
        rm -rf -- "$work_dir"
        return 40
    fi
    rm -rf -- "$work_dir"
    printf '1Panel 官方安装入口下载和 SHA-256 预检通过；没有执行安装脚本。\n'
}

panel_apply() {
    local expected=$INSTALL_SHA256 work_dir script
    vps_require_root || return $?
    panel_check || return $?
    command -v 1pctl >/dev/null 2>&1 && { printf '1Panel 已安装。\n'; return 10; }
    [[ ${1:-} == --sha256 ]] && expected=${2:-}
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || {
        printf '1Panel 安装脚本目录缺少有效的 SHA-256。\n' >&2
        return 64
    }
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-1panel.XXXXXX") || return 40
    script="$work_dir/quick_start.sh"
    if ! panel_fetch_verified "$script" "$expected"; then
        rm -rf -- "$work_dir"
        return 40
    fi
    bash "$script"
    local result=$?
    rm -rf -- "$work_dir"
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
    preflight) panel_preflight ;;
    apply) shift; panel_apply "$@" ;;
    verify) panel_verify ;;
    uninstall) panel_uninstall ;;
    *) printf 'applications.1panel 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
