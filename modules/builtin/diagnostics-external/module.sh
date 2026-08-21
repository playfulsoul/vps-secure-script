#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/installer.sh
source "$VPS_PLATFORM_ROOT/core/installer.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

diagnostic_url() {
    if [[ -n ${VPS_DIAGNOSTIC_URL:-} ]]; then
        printf '%s\n' "$VPS_DIAGNOSTIC_URL"
        return 0
    fi
    case ${1:-} in
        yabs) printf 'https://raw.githubusercontent.com/masonr/yet-another-bench-script/f8c6a48cd6ff85b54c5cd2504f0807462dc58938/yabs.sh\n' ;;
        bench) printf 'https://raw.githubusercontent.com/teddysun/across/fdb40962837b2e24bc94b87c2b1786ad2308489a/bench.sh\n' ;;
        media) printf 'https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/b6d4a6f9a87fc6eae6d3e62d0092ececcec8e844/check.sh\n' ;;
        nexttrace) printf 'https://raw.githubusercontent.com/nxtrace/NTrace-core/d50f6557562a38c62ebf4d4340021fb5824f06ab/nt_install.sh\n' ;;
        fusion) printf 'https://raw.githubusercontent.com/spiritLHLS/ecs/f0955b5eda007c62c591abbb52220c10bbf7a107/ecs.sh\n' ;;
        ip-quality) printf 'https://raw.githubusercontent.com/playfulsoul/IPQuality/3115e8ca0e3537ef201bb6c6f5e6cc08233987fe/ip.sh\n' ;;
        *) return 1 ;;
    esac
}

diagnostic_sha256() {
    if [[ -n ${VPS_DIAGNOSTIC_SHA256:-} ]]; then
        printf '%s\n' "$VPS_DIAGNOSTIC_SHA256"
        return 0
    fi
    case ${1:-} in
        yabs) printf '8d2bccbf1dd74f09e09233dc5286a13a17183bd304bc818e75b4ac6066c9e095\n' ;;
        bench) printf 'fbc7d7ec27f59939ba798f456ed3d31931c6d3d4604a63e6d563b19a4974ae04\n' ;;
        media) printf '9c0ec7f81a39743c91df9636924f7b308b96fbc038b84b95040d6eb48f8da8cd\n' ;;
        nexttrace) printf '8b5e21e7bb662a24d75ea9c15a5a3602bced1e71fdbbd5c99f00f730811f2b6c\n' ;;
        fusion) printf 'a7da670e5ab8a34ee33388a4b07b87b9646208c14e0fb4396d1566676a3c186e\n' ;;
        ip-quality) printf '6ac29889056dd82e95b81f7b3ec17adc462561c30e18929e0142abfdaa190f3e\n' ;;
        *) return 1 ;;
    esac
}

diagnostic_name() {
    case ${1:-} in
        yabs) printf 'YABS CPU、磁盘与网络测试\n' ;;
        bench) printf 'Bench.sh 网络带宽测试\n' ;;
        media) printf '流媒体解锁检测\n' ;;
        nexttrace) printf 'NextTrace 回程路由测试\n' ;;
        fusion) printf '融合怪综合测试\n' ;;
        ip-quality) printf 'IP 地址质量检测\n' ;;
        *) return 1 ;;
    esac
}

diagnostic_license() {
    case ${1:-} in
        yabs) printf 'WTFPL\n' ;;
        bench) printf 'Apache-2.0\n' ;;
        media|ip-quality) printf 'AGPL-3.0\n' ;;
        nexttrace) printf 'GPL-3.0\n' ;;
        fusion) printf 'MIT\n' ;;
        *) return 1 ;;
    esac
}

diagnostics_check() {
    command -v curl >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 || return 20
}

diagnostics_status() {
    local tool name
    for tool in yabs bench media nexttrace fusion ip-quality; do
        name=$(diagnostic_name "$tool")
        printf '%s (%s)\n' "$name" "$tool"
        printf '  来源: %s\n' "$(diagnostic_url "$tool")"
        printf '  SHA-256: %s\n' "$(diagnostic_sha256 "$tool")"
        printf '  许可证: %s\n\n' "$(diagnostic_license "$tool")"
    done
    printf '目录固定了入口脚本的提交和 SHA-256；部分工具运行时仍会下载上游组件。\n'
}

diagnostics_plan() {
    local tool=${1:-} url
    url=$(diagnostic_url "$tool" 2>/dev/null || true)
    [[ -n "$url" ]] || {
        printf '用法: plan <yabs|bench|media|nexttrace|fusion|ip-quality>\n' >&2
        return 64
    }
    printf '外部诊断执行计划：\n'
    printf '  - 工具: %s\n' "$(diagnostic_name "$tool")"
    printf '  - 固定来源: %s\n' "$url"
    printf '  - 内置 SHA-256: %s\n' "$(diagnostic_sha256 "$tool")"
    printf '  - 下载到临时文件并验证平台目录中的 SHA-256。\n'
    printf '  - 校验成功后才执行，完成后删除临时文件。\n'
    printf '  - 入口脚本仍可能下载其他上游组件，属于外部 root 代码。\n'
}

diagnostics_expected_sha256() {
    local tool=${1:-} marker=${2:-} supplied=${3:-}
    local expected
    expected=$(diagnostic_sha256 "$tool" 2>/dev/null || true)
    if [[ -n "$marker" ]]; then
        [[ "$marker" == --sha256 && "$supplied" =~ ^[a-fA-F0-9]{64}$ ]] || {
            printf '用法: configure <工具> [--sha256 <已审查脚本摘要>]\n' >&2
            return 64
        }
        expected=$supplied
    fi
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || {
        printf '未知工具或目录缺少校验值。\n' >&2
        return 64
    }
    printf '%s\n' "$expected"
}

diagnostics_fetch_verified() {
    local tool=$1 expected=$2 destination=$3 url actual
    url=$(diagnostic_url "$tool" 2>/dev/null || true)
    [[ -n "$url" ]] || return 64
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 5 --max-time 120 "$url" -o "$destination"; then
        return 40
    fi
    actual=$(vps_sha256 "$destination") || return 40
    if [[ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" != \
          "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]]; then
        printf '外部诊断脚本 SHA-256 不匹配。\n' >&2
        return 40
    fi
}

diagnostics_preflight() {
    local tool=${1:-} expected work_dir script
    diagnostics_check || return $?
    expected=$(diagnostics_expected_sha256 "$tool") || return $?
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-diagnostic-preflight.XXXXXX") || return 40
    script="$work_dir/$tool.sh"
    if ! diagnostics_fetch_verified "$tool" "$expected" "$script"; then
        rm -rf -- "$work_dir"
        return 40
    fi
    rm -rf -- "$work_dir"
    printf '%s 入口脚本下载和 SHA-256 预检通过；没有执行第三方代码。\n' \
        "$(diagnostic_name "$tool")"
}

diagnostics_run() {
    local tool=${1:-} marker=${2:-} supplied=${3:-}
    local expected work_dir script result
    vps_require_root || return $?
    diagnostics_check || return $?
    expected=$(diagnostics_expected_sha256 "$tool" "$marker" "$supplied") || return $?
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-diagnostic.XXXXXX") || return 40
    script="$work_dir/$tool.sh"
    if ! diagnostics_fetch_verified "$tool" "$expected" "$script"; then
        rm -rf -- "$work_dir"
        return 40
    fi
    if [[ "$tool" == nexttrace ]]; then
        if sh "$script" --system && command -v nexttrace >/dev/null 2>&1; then
            nexttrace --fast-trace
            result=$?
        else
            result=1
        fi
    else
        bash "$script"
        result=$?
    fi
    rm -rf -- "$work_dir"
    return "$result"
}

case ${1:-} in
    check) diagnostics_check ;;
    status|doctor) diagnostics_status ;;
    plan) shift; diagnostics_plan "$@" ;;
    preflight) shift; diagnostics_preflight "$@" ;;
    configure) shift; diagnostics_run "$@" ;;
    *) printf 'diagnostics.external 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
