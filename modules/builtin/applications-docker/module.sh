#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/packages.sh
source "$VPS_PLATFORM_ROOT/core/packages.sh"
# shellcheck source=../../../core/platform.sh
source "$VPS_PLATFORM_ROOT/core/platform.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"

DOCKER_KEY=${VPS_DOCKER_KEY:-/etc/apt/keyrings/docker.asc}
DOCKER_SOURCE=${VPS_DOCKER_SOURCE:-/etc/apt/sources.list.d/docker.sources}

docker_platform() {
    local platform codename
    platform=$(vps_platform_id 2>/dev/null || true)
    codename=$(vps_os_release_value VERSION_CODENAME 2>/dev/null || true)
    case "$platform" in
        debian|ubuntu) ;;
        *) printf 'Docker 官方 APT 模块不支持平台: %s\n' "${platform:-unknown}" >&2; return 20 ;;
    esac
    [[ -n "$codename" ]] || { printf '缺少 VERSION_CODENAME。\n' >&2; return 20; }
    printf '%s %s\n' "$platform" "$codename"
}

docker_conflicts() {
    local package
    for package in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
            printf '%s\n' "$package"
        fi
    done
}

docker_check() {
    vps_require_apt || return $?
    docker_platform >/dev/null || return $?
    command -v dpkg >/dev/null 2>&1 || return 20
}

docker_plan() {
    local platform_data conflicts
    docker_check || return $?
    platform_data=$(docker_platform)
    conflicts=$(docker_conflicts)
    printf 'Docker 执行计划：\n'
    printf '  - 使用 Docker 官方 %s APT 仓库。\n' "${platform_data%% *}"
    printf '  - 安装 docker-ce、CLI、containerd、buildx 和 compose 插件。\n'
    printf '  - 不使用 get.docker.com 便利脚本。\n'
    printf '  - 不自动删除镜像、容器或卷。\n'
    printf '  - Docker 发布端口可能绕过 UFW，安装后必须审查端口策略。\n'
    if [[ -n "$conflicts" ]]; then
        printf '  - 检测到冲突包，应用将停止: %s\n' "$(printf '%s\n' "$conflicts" | paste -sd, -)"
    fi
}

docker_status() {
    if ! command -v docker >/dev/null 2>&1; then
        printf 'Docker 未安装。\n'
        return 10
    fi
    docker version --format 'Client: {{.Client.Version}} Server: {{.Server.Version}}' 2>/dev/null || docker --version
    systemctl is-active docker 2>/dev/null || true
}

docker_verify() {
    command -v docker >/dev/null 2>&1 || return 50
    systemctl is-active --quiet docker || return 50
    docker info >/dev/null 2>&1 || return 50
    printf 'Docker Engine 已安装且服务可用。\n'
}

docker_apply() {
    local platform codename architecture conflicts key_url temporary_key
    vps_require_root || return $?
    docker_check || return $?
    command -v docker >/dev/null 2>&1 && { printf 'Docker 已安装。\n'; return 10; }
    conflicts=$(docker_conflicts)
    [[ -z "$conflicts" ]] || {
        printf '请先审查并移除冲突包: %s\n' "$(printf '%s\n' "$conflicts" | paste -sd, -)" >&2
        return 30
    }
    if [[ -e "$DOCKER_KEY" || -e "$DOCKER_SOURCE" ]]; then
        printf '检测到现有 Docker 仓库配置。为避免覆盖，请先人工审查 %s 和 %s。\n' \
            "$DOCKER_KEY" "$DOCKER_SOURCE" >&2
        return 30
    fi

    read -r platform codename <<< "$(docker_platform)"
    architecture=$(dpkg --print-architecture)
    key_url="https://download.docker.com/linux/$platform/gpg"
    vps_apt_update || return 40
    vps_apt_install ca-certificates curl || return 40
    install -d -m 755 /etc/apt/keyrings || return 40
    temporary_key=$(mktemp) || return 40
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$key_url" -o "$temporary_key"; then
        rm -f "$temporary_key"
        return 40
    fi
    install -m 644 "$temporary_key" "$DOCKER_KEY" || { rm -f "$temporary_key"; return 40; }
    rm -f "$temporary_key"

    cat > "$DOCKER_SOURCE" <<EOF
Types: deb
URIs: https://download.docker.com/linux/$platform
Suites: $codename
Components: stable
Architectures: $architecture
Signed-By: $DOCKER_KEY
EOF
    vps_apt_update || return 40
    vps_apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 40
    systemctl enable --now docker || return 40
    docker_verify
}

docker_uninstall() {
    vps_require_root || return $?
    vps_require_apt || return $?
    DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || return 40
    printf 'Docker Engine 软件包已卸载；/var/lib/docker 和卷数据均保留。\n'
}

case ${1:-} in
    check) docker_check ;;
    plan) docker_plan ;;
    status|doctor) docker_status ;;
    apply) docker_apply ;;
    verify) docker_verify ;;
    uninstall) docker_uninstall ;;
    *) printf 'applications.docker 不支持操作: %s\n' "${1:-}" >&2; exit 64 ;;
esac
