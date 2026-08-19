#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/installer.sh
source "$VPS_PLATFORM_ROOT/core/installer.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

diagnostic_url() {
    case ${1:-} in
        yabs) printf 'https://yabs.sh\n' ;;
        bench) printf 'https://bench.sh\n' ;;
        media) printf 'https://check.unlock.media\n' ;;
        nexttrace) printf 'https://nxtrace.org/nt\n' ;;
        fusion) printf 'https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh\n' ;;
        ip-quality) printf 'https://raw.githubusercontent.com/playfulsoul/IPQuality/main/ip.sh\n' ;;
        *) return 1 ;;
    esac
}

diagnostics_check() {
    command -v curl >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 || return 20
}

diagnostics_status() {
    printf '%-14s %s\n' TOOL SOURCE
    local tool
    for tool in yabs bench media nexttrace fusion ip-quality; do
        printf '%-14s %s\n' "$tool" "$(diagnostic_url "$tool")"
    done
    printf '\n这些工具不会直接从远程地址执行。\n'
}

diagnostics_plan() {
    local tool=${1:-} url
    url=$(diagnostic_url "$tool" 2>/dev/null || true)
    [[ -n "$url" ]] || {
        printf '用法: plan <yabs|bench|media|nexttrace|fusion|ip-quality>\n' >&2
        return 64
    }
    printf '外部诊断执行计划：\n'
    printf '  - 工具: %s\n' "$tool"
    printf '  - 下载地址: %s\n' "$url"
    printf '  - 下载到临时文件并验证用户提供的 SHA-256。\n'
    printf '  - 校验成功后才执行，完成后删除临时文件。\n'
    printf '  - 仍属于外部 root 代码，执行前必须审查。\n'
}

diagnostics_run() {
    local tool=${1:-} marker=${2:-} expected=${3:-} url work_dir script actual result
    vps_require_root || return $?
    diagnostics_check || return $?
    url=$(diagnostic_url "$tool" 2>/dev/null || true)
    [[ -n "$url" && "$marker" == --sha256 && "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || {
        printf '用法: configure <工具> --sha256 <已审查脚本摘要>\n' >&2
        return 64
    }
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-diagnostic.XXXXXX") || return 40
    script="$work_dir/$tool.sh"
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$url" -o "$script"; then
        rm -rf "$work_dir"
        return 40
    fi
    actual=$(vps_sha256 "$script") || { rm -rf "$work_dir"; return 40; }
    if [[ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" != \
          "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]]; then
        printf '外部诊断脚本 SHA-256 不匹配。\n' >&2
        rm -rf "$work_dir"
        return 40
    fi
    bash "$script"
    result=$?
    rm -rf "$work_dir"
    return "$result"
}

case ${1:-} in
    check) diagnostics_check ;;
    status|doctor) diagnostics_status ;;
    plan) shift; diagnostics_plan "$@" ;;
    configure) shift; diagnostics_run "$@" ;;
    *) printf 'diagnostics.external 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
