#!/usr/bin/env bash

set -u

MODULE_DIR=${VPS_MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
VPS_PLATFORM_ROOT=${VPS_PLATFORM_ROOT:-$(cd -- "$MODULE_DIR/../../.." && pwd)}

# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"
# shellcheck source=../../../core/platform.sh
source "$VPS_PLATFORM_ROOT/core/platform.sh"

BESZEL_AGENT_VERSION=${VPS_BESZEL_AGENT_VERSION:-0.20.0}
BESZEL_AGENT_CONFIG_DIR=${VPS_BESZEL_AGENT_CONFIG_DIR:-/etc/vps-secure-beszel-agent}
BESZEL_AGENT_ENV_FILE=${VPS_BESZEL_AGENT_ENV_FILE:-$BESZEL_AGENT_CONFIG_DIR/agent.env}
BESZEL_AGENT_KEY_FILE=${VPS_BESZEL_AGENT_KEY_FILE:-$BESZEL_AGENT_CONFIG_DIR/hub-key}
BESZEL_AGENT_TOKEN_FILE=${VPS_BESZEL_AGENT_TOKEN_FILE:-$BESZEL_AGENT_CONFIG_DIR/hub-token}
BESZEL_AGENT_INSTALL_DIR=${VPS_BESZEL_AGENT_INSTALL_DIR:-/usr/local/lib/vps-secure/managed/beszel-agent}
BESZEL_AGENT_BINARY=${VPS_BESZEL_AGENT_BINARY:-$BESZEL_AGENT_INSTALL_DIR/beszel-agent}
BESZEL_AGENT_VERSION_FILE=${VPS_BESZEL_AGENT_VERSION_FILE:-$BESZEL_AGENT_INSTALL_DIR/version}
BESZEL_AGENT_DATA_DIR=${VPS_BESZEL_AGENT_DATA_DIR:-/var/lib/vps-secure-beszel-agent}
BESZEL_AGENT_SERVICE_FILE=${VPS_BESZEL_AGENT_SERVICE_FILE:-/etc/systemd/system/vps-secure-beszel-agent.service}
BESZEL_AGENT_SERVICE=${VPS_BESZEL_AGENT_SERVICE:-vps-secure-beszel-agent.service}
BESZEL_AGENT_USER=${VPS_BESZEL_AGENT_USER:-beszel}
BESZEL_AGENT_GROUP=${VPS_BESZEL_AGENT_GROUP:-$BESZEL_AGENT_USER}
BESZEL_AGENT_RELEASE_ROOT=${VPS_BESZEL_AGENT_RELEASE_ROOT:-https://github.com/henrygd/beszel/releases/download}

beszel_agent_file_mode() {
    local file=$1
    stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null
}

beszel_agent_sha256() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{ print $1 }'
    else
        printf '缺少 SHA-256 校验工具。\n' >&2
        return 20
    fi
}

beszel_agent_validate_version() {
    [[ ${1:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        printf 'Beszel 版本格式无效。\n' >&2
        return 64
    }
}

beszel_agent_validate_hub_url() {
    local url=${1:-} authority host port
    [[ "$url" == https://* ]] || {
        printf 'Hub 地址必须使用 HTTPS。\n' >&2
        return 64
    }
    [[ "$url" != *[[:space:]]* && "$url" != *'@'* && "$url" != *'?'* && "$url" != *'#'* ]] || {
        printf 'Hub 地址不能包含凭据、查询参数、片段或空白。\n' >&2
        return 64
    }
    authority=${url#https://}
    authority=${authority%%/*}
    [[ -n "$authority" ]] || { printf 'Hub 地址缺少主机名。\n' >&2; return 64; }
    host=${authority%%:*}
    port=''
    if [[ "$authority" == *:* ]]; then
        port=${authority##*:}
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            printf 'Hub 地址端口无效。\n' >&2
            return 64
        fi
    fi
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$host" == *.* ]] || {
        printf 'Hub 地址必须使用稳定的 DNS 主机名，不能使用裸 IP。\n' >&2
        return 64
    }
    [[ ! "$host" =~ ^[0-9.]+$ ]] || {
        printf 'Hub 地址必须使用稳定的 DNS 主机名，不能使用裸 IP。\n' >&2
        return 64
    }
    [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/%+-]*)?$ ]] || {
        printf 'Hub 地址包含不受支持的字符。\n' >&2
        return 64
    }
}

beszel_agent_validate_source_secret() {
    local file=${1:-} label=$2 mode
    [[ -n "$file" && -f "$file" && ! -L "$file" && -s "$file" ]] || {
        printf '%s必须是非空的普通文件，且不能是符号链接。\n' "$label" >&2
        return 64
    }
    mode=$(beszel_agent_file_mode "$file") || {
        printf '无法检查%s权限。\n' "$label" >&2
        return 64
    }
    if (( (8#$mode & 077) != 0 )); then
        printf '%s权限过宽；请设置为 600 后重试。\n' "$label" >&2
        return 64
    fi
    if [[ $(wc -c < "$file") -gt 4096 ]]; then
        printf '%s内容异常过大。\n' "$label" >&2
        return 64
    fi
}

beszel_agent_validate_token_file() {
    local file=$1 token
    beszel_agent_validate_source_secret "$file" 'Token 文件' || return $?
    IFS= read -r token < "$file"
    [[ -n "$token" && "$token" != *[[:space:]]* ]] || {
        printf 'Token 文件必须只包含一行非空 Token。\n' >&2
        return 64
    }
    [[ $(wc -l < "$file") -le 1 ]] || {
        printf 'Token 文件必须只包含一行非空 Token。\n' >&2
        return 64
    }
}

beszel_agent_validate_key_file() {
    local file=$1 first_line
    beszel_agent_validate_source_secret "$file" 'Hub 公钥文件' || return $?
    first_line=$(awk 'NF && $1 !~ /^#/ { print; exit }' "$file")
    [[ "$first_line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || {
        printf 'Hub 公钥文件格式无效。\n' >&2
        return 64
    }
}

beszel_agent_parse_join_args() {
    BESZEL_JOIN_HUB_URL=''
    BESZEL_JOIN_KEY_SOURCE=''
    BESZEL_JOIN_TOKEN_SOURCE=''
    BESZEL_JOIN_VERSION=$BESZEL_AGENT_VERSION
    while (( $# > 0 )); do
        case $1 in
            --hub-url|--key-file|--token-file|--version)
                (( $# >= 2 )) || { printf 'Beszel Agent 参数缺少值: %s\n' "$1" >&2; return 64; }
                ;;
        esac
        case $1 in
            --hub-url) BESZEL_JOIN_HUB_URL=${2:-}; shift 2 ;;
            --key-file) BESZEL_JOIN_KEY_SOURCE=${2:-}; shift 2 ;;
            --token-file) BESZEL_JOIN_TOKEN_SOURCE=${2:-}; shift 2 ;;
            --version) BESZEL_JOIN_VERSION=${2:-}; shift 2 ;;
            *) printf '未知参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    beszel_agent_validate_hub_url "$BESZEL_JOIN_HUB_URL" || return $?
    beszel_agent_validate_version "$BESZEL_JOIN_VERSION" || return $?
    beszel_agent_validate_key_file "$BESZEL_JOIN_KEY_SOURCE" || return $?
    beszel_agent_validate_token_file "$BESZEL_JOIN_TOKEN_SOURCE" || return $?
}

beszel_agent_platform_asset() {
    local kernel machine
    kernel=$(uname -s)
    machine=$(uname -m)
    [[ "$kernel" == Linux ]] || {
        printf '当前模块只支持 Linux。\n' >&2
        return 20
    }
    case "$machine" in
        x86_64|amd64) printf 'beszel-agent_linux_amd64.tar.gz\n' ;;
        aarch64|arm64) printf 'beszel-agent_linux_arm64.tar.gz\n' ;;
        *) printf '暂不支持此 CPU 架构: %s\n' "$machine" >&2; return 20 ;;
    esac
}

beszel_agent_check() {
    local platform
    platform=$(vps_platform_id 2>/dev/null || true)
    case "$platform" in
        debian|ubuntu) ;;
        *) printf '当前模块只支持 Debian 和 Ubuntu。\n' >&2; return 20 ;;
    esac
    command -v systemctl >/dev/null 2>&1 || { printf '缺少 systemd。\n' >&2; return 20; }
    command -v curl >/dev/null 2>&1 || { printf '缺少 curl。\n' >&2; return 20; }
    command -v tar >/dev/null 2>&1 || { printf '缺少 tar。\n' >&2; return 20; }
    beszel_agent_platform_asset >/dev/null || return $?
    beszel_agent_sha256 "$VPS_PLATFORM_ROOT/VERSION" >/dev/null || return $?
    printf '系统支持 Beszel Agent 的受控安装。\n'
}

beszel_agent_plan() {
    beszel_agent_parse_join_args "$@" || return $?
    printf 'Beszel 中央监控接入计划：\n'
    printf '  - Hub: %s\n' "$BESZEL_JOIN_HUB_URL"
    printf '  - Agent 版本: %s（固定版本）\n' "$BESZEL_JOIN_VERSION"
    printf '  - 下载官方 Release 和同版本校验清单，校验通过后原子安装。\n'
    printf '  - Agent 仅主动连接 Hub，并关闭内置 SSH 监听。\n'
    printf '  - Token 和 Hub 公钥保存在 600 权限文件中，不写入服务参数或日志。\n'
    printf '  - 不修改 UFW，不开放入站端口，不授予 Docker 或磁盘设备权限。\n'
    printf '  - 本地服务正常不等于中央 Hub 已收到数据，最终需要在 Hub 页面验收。\n'
}

beszel_agent_unit_owned() {
    [[ ! -e "$BESZEL_AGENT_SERVICE_FILE" ]] && return 0
    grep -q '^# Managed by VPS Secure: monitoring.beszel-agent$' "$BESZEL_AGENT_SERVICE_FILE"
}

beszel_agent_preflight() {
    beszel_agent_parse_join_args "$@" || return $?
    beszel_agent_check >/dev/null || return $?
    beszel_agent_unit_owned || {
        printf '目标 systemd 服务文件不是本模块创建的，已停止以避免覆盖。\n' >&2
        return 30
    }
    if systemctl list-unit-files beszel-agent.service >/dev/null 2>&1 && \
       systemctl cat beszel-agent.service >/dev/null 2>&1; then
        printf '检测到其他 Beszel Agent 服务 beszel-agent.service，请先人工审查，避免双实例。\n' >&2
        return 30
    fi
    beszel_agent_probe_hub "$BESZEL_JOIN_HUB_URL" || return $?
    printf '预检通过：未发现需要覆盖的第三方 Beszel Agent 服务。\n'
}

beszel_agent_probe_hub() {
    local hub_url=$1 health_url=${1%/}/api/health
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 5 --max-time 15 -- "$health_url" >/dev/null; then
        printf '无法通过 HTTPS 访问 Hub 健康接口: %s\n' "$hub_url" >&2
        return 30
    fi
}

beszel_agent_extract_release_archive() {
    local archive=$1 destination=$2 entries
    entries=$(tar -tzf "$archive" 2>/dev/null | LC_ALL=C sort) || {
        printf 'Beszel Agent 压缩包无法读取。\n' >&2
        return 40
    }
    [[ "$entries" == $'LICENSE\nbeszel-agent\nreadme.md' ]] || {
        printf 'Beszel Agent 压缩包结构异常。\n' >&2
        return 40
    }
    if ! LC_ALL=C tar -tvzf "$archive" | awk '$1 !~ /^-/ { bad = 1 } END { exit bad }'; then
        printf 'Beszel Agent 压缩包包含非普通文件。\n' >&2
        return 40
    fi
    tar -xOzf "$archive" beszel-agent > "$destination/beszel-agent" || return 40
    [[ -s "$destination/beszel-agent" ]] || return 40
    chmod 755 "$destination/beszel-agent" || return 40
}

beszel_agent_fetch_release() {
    local version=$1 destination=$2 asset checksums_url archive_url expected actual
    asset=$(beszel_agent_platform_asset) || return $?
    checksums_url="$BESZEL_AGENT_RELEASE_ROOT/v$version/beszel_${version}_checksums.txt"
    archive_url="$BESZEL_AGENT_RELEASE_ROOT/v$version/$asset"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 120 "$checksums_url" -o "$destination/checksums.txt" || return 40
    expected=$(awk -v name="$asset" '$2 == name { print $1; exit }' "$destination/checksums.txt")
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || {
        printf '官方校验清单中缺少目标文件。\n' >&2
        return 40
    }
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 300 "$archive_url" -o "$destination/agent.tar.gz" || return 40
    actual=$(beszel_agent_sha256 "$destination/agent.tar.gz") || return 40
    [[ "${actual,,}" == "${expected,,}" ]] || {
        printf 'Beszel Agent 下载文件校验失败。\n' >&2
        return 40
    }
    beszel_agent_extract_release_archive "$destination/agent.tar.gz" "$destination"
}

beszel_agent_record_file() {
    local transaction=$1 label=$2 path=$3 mode
    if [[ -e "$path" ]]; then
        mode=$(beszel_agent_file_mode "$path") || return 1
        cp -p -- "$path" "$transaction/$label" || return 1
        printf '%s\n' "$mode" > "$transaction/$label.mode" || return 1
        printf '%s\n' present > "$transaction/$label.state" || return 1
    else
        printf '%s\n' absent > "$transaction/$label.state" || return 1
    fi
}

beszel_agent_record_service_state() {
    local transaction=$1
    if systemctl is-enabled --quiet "$BESZEL_AGENT_SERVICE" 2>/dev/null; then
        printf 'enabled\n' > "$transaction/service.enabled"
    else
        printf 'disabled\n' > "$transaction/service.enabled"
    fi
    if systemctl is-active --quiet "$BESZEL_AGENT_SERVICE" 2>/dev/null; then
        printf 'active\n' > "$transaction/service.active"
    else
        printf 'inactive\n' > "$transaction/service.active"
    fi
}

beszel_agent_create_transaction() {
    local state_root module_state transactions transaction
    state_root=$(vps_state_root)
    module_state=$(vps_module_state_dir monitoring.beszel-agent)
    transactions="$module_state/transactions"
    mkdir -p "$transactions" || return 40
    transaction=$(mktemp -d "$transactions/$(vps_timestamp)-$$-XXXXXX") || return 40
    chmod 700 "$state_root" "$state_root/modules" "$module_state" \
        "$transactions" "$transaction" || return 40
    beszel_agent_record_file "$transaction" binary "$BESZEL_AGENT_BINARY" || return 40
    beszel_agent_record_file "$transaction" version "$BESZEL_AGENT_VERSION_FILE" || return 40
    beszel_agent_record_file "$transaction" env "$BESZEL_AGENT_ENV_FILE" || return 40
    beszel_agent_record_file "$transaction" key "$BESZEL_AGENT_KEY_FILE" || return 40
    beszel_agent_record_file "$transaction" token "$BESZEL_AGENT_TOKEN_FILE" || return 40
    beszel_agent_record_file "$transaction" service "$BESZEL_AGENT_SERVICE_FILE" || return 40
    beszel_agent_record_service_state "$transaction" || return 40
    chmod 700 "$transaction" || return 40
    find "$transaction" -type f -exec chmod 600 {} + || return 40
    printf '%s\n' "$transaction"
}

beszel_agent_restore_file() {
    local transaction=$1 label=$2 path=$3 state mode
    state=$(<"$transaction/$label.state")
    if [[ "$state" == present ]]; then
        mode=$(<"$transaction/$label.mode")
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        mkdir -p "$(dirname -- "$path")" || return 1
        install -m "$mode" "$transaction/$label" "$path" || return 1
    else
        rm -f -- "$path" || return 1
    fi
}

beszel_agent_restore_transaction() {
    local transaction=$1 enabled active
    systemctl stop "$BESZEL_AGENT_SERVICE" >/dev/null 2>&1 || true
    beszel_agent_restore_file "$transaction" binary "$BESZEL_AGENT_BINARY" || return 60
    beszel_agent_restore_file "$transaction" version "$BESZEL_AGENT_VERSION_FILE" || return 60
    beszel_agent_restore_file "$transaction" env "$BESZEL_AGENT_ENV_FILE" || return 60
    beszel_agent_restore_file "$transaction" key "$BESZEL_AGENT_KEY_FILE" || return 60
    beszel_agent_restore_file "$transaction" token "$BESZEL_AGENT_TOKEN_FILE" || return 60
    beszel_agent_restore_file "$transaction" service "$BESZEL_AGENT_SERVICE_FILE" || return 60
    systemctl daemon-reload || return 60
    enabled=$(<"$transaction/service.enabled")
    active=$(<"$transaction/service.active")
    if [[ "$enabled" == enabled ]]; then
        systemctl enable "$BESZEL_AGENT_SERVICE" >/dev/null || return 60
    else
        systemctl disable "$BESZEL_AGENT_SERVICE" >/dev/null 2>&1 || true
    fi
    if [[ "$active" == active ]]; then
        systemctl start "$BESZEL_AGENT_SERVICE" || return 60
    fi
}

beszel_agent_write_candidate() {
    local destination=$1 hub_url=$2 key_source=$3 token_source=$4
    mkdir -p "$destination" || return 40
    printf '%s\n' \
        "HUB_URL=$hub_url" \
        "KEY_FILE=$BESZEL_AGENT_KEY_FILE" \
        "TOKEN_FILE=$BESZEL_AGENT_TOKEN_FILE" \
        "DATA_DIR=$BESZEL_AGENT_DATA_DIR" \
        'DISABLE_SSH=true' \
        'DOCKER_HOST=' > "$destination/agent.env" || return 40
    cp -- "$key_source" "$destination/hub-key" || return 40
    cp -- "$token_source" "$destination/hub-token" || return 40
    chmod 600 "$destination/agent.env" "$destination/hub-key" "$destination/hub-token" || return 40
    cat > "$destination/service" <<EOF
# Managed by VPS Secure: monitoring.beszel-agent
[Unit]
Description=VPS Secure managed Beszel Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$BESZEL_AGENT_USER
Group=$BESZEL_AGENT_GROUP
EnvironmentFile=$BESZEL_AGENT_ENV_FILE
ExecStart=$BESZEL_AGENT_BINARY
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectClock=yes
ProtectHome=yes
ProtectKernelLogs=yes
ProtectSystem=strict
ReadWritePaths=$BESZEL_AGENT_DATA_DIR
LockPersonality=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$destination/service" || return 40
}

beszel_agent_config_hub_url() {
    [[ -r "$BESZEL_AGENT_ENV_FILE" ]] || return 1
    awk -F= '$1 == "HUB_URL" { sub(/^HUB_URL=/, ""); print; exit }' "$BESZEL_AGENT_ENV_FILE"
}

beszel_agent_desired_state_matches() {
    local hub_url=$1 key_source=$2 token_source=$3 version=$4
    [[ -x "$BESZEL_AGENT_BINARY" && -r "$BESZEL_AGENT_VERSION_FILE" ]] || return 1
    [[ $(<"$BESZEL_AGENT_VERSION_FILE") == "$version" ]] || return 1
    [[ $(beszel_agent_config_hub_url 2>/dev/null || true) == "$hub_url" ]] || return 1
    cmp -s -- "$key_source" "$BESZEL_AGENT_KEY_FILE" || return 1
    cmp -s -- "$token_source" "$BESZEL_AGENT_TOKEN_FILE" || return 1
    beszel_agent_unit_owned || return 1
    systemctl is-enabled --quiet "$BESZEL_AGENT_SERVICE" 2>/dev/null || return 1
    systemctl is-active --quiet "$BESZEL_AGENT_SERVICE" 2>/dev/null || return 1
}

beszel_agent_install_user() {
    if id "$BESZEL_AGENT_USER" >/dev/null 2>&1; then
        return 0
    fi
    useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$BESZEL_AGENT_USER" || return 40
}

beszel_agent_verify_files() {
    local mode group
    [[ -x "$BESZEL_AGENT_BINARY" && -s "$BESZEL_AGENT_BINARY" ]] || return 50
    [[ -r "$BESZEL_AGENT_VERSION_FILE" ]] || return 50
    [[ -r "$BESZEL_AGENT_ENV_FILE" && -r "$BESZEL_AGENT_KEY_FILE" && -r "$BESZEL_AGENT_TOKEN_FILE" ]] || return 50
    beszel_agent_unit_owned || return 50
    mode=$(beszel_agent_file_mode "$BESZEL_AGENT_CONFIG_DIR") || return 50
    [[ "$mode" == 710 ]] || return 50
    group=$(stat -c '%G' "$BESZEL_AGENT_CONFIG_DIR" 2>/dev/null || \
        stat -f '%Sg' "$BESZEL_AGENT_CONFIG_DIR" 2>/dev/null) || return 50
    [[ "$group" == "$BESZEL_AGENT_GROUP" ]] || return 50
    for file in "$BESZEL_AGENT_ENV_FILE" "$BESZEL_AGENT_KEY_FILE" "$BESZEL_AGENT_TOKEN_FILE"; do
        mode=$(beszel_agent_file_mode "$file") || return 50
        (( (8#$mode & 077) == 0 )) || return 50
    done
    if (( EUID == 0 )) && command -v runuser >/dev/null 2>&1; then
        runuser -u "$BESZEL_AGENT_USER" -- test -r "$BESZEL_AGENT_KEY_FILE" || return 50
        runuser -u "$BESZEL_AGENT_USER" -- test -r "$BESZEL_AGENT_TOKEN_FILE" || return 50
    fi
}

beszel_agent_wait_active() {
    local attempt state
    for ((attempt = 0; attempt < 10; attempt++)); do
        state=$(systemctl is-active "$BESZEL_AGENT_SERVICE" 2>/dev/null || true)
        [[ "$state" == active ]] && return 0
        sleep 1
    done
    return 50
}

beszel_agent_verify() {
    local hub_url
    beszel_agent_verify_files || {
        printf 'Beszel Agent 文件或权限验证失败。\n' >&2
        return 50
    }
    systemctl is-enabled --quiet "$BESZEL_AGENT_SERVICE" || return 50
    systemctl is-active --quiet "$BESZEL_AGENT_SERVICE" || return 50
    hub_url=$(beszel_agent_config_hub_url) || return 50
    beszel_agent_probe_hub "$hub_url" || return 50
    printf '本地安装、受保护配置和 systemd 服务已通过验证。\n'
    printf '配置的 Hub: %s\n' "$hub_url"
    printf 'Hub HTTPS 健康接口可达。\n'
    printf '注意：以上仍不等于中央 Hub 已收到本机数据；请在 Hub 页面确认最新采样时间。\n'
}

beszel_agent_apply() {
    local work_dir candidate transaction
    vps_require_root || return $?
    beszel_agent_parse_join_args "$@" || return $?
    beszel_agent_desired_state_matches "$BESZEL_JOIN_HUB_URL" "$BESZEL_JOIN_KEY_SOURCE" \
        "$BESZEL_JOIN_TOKEN_SOURCE" "$BESZEL_JOIN_VERSION" && {
        printf 'Beszel Agent 已按相同配置运行，无需修改。\n'
        return 10
    }
    if [[ -e "$BESZEL_AGENT_BINARY" || -e "$BESZEL_AGENT_ENV_FILE" || -e "$BESZEL_AGENT_SERVICE_FILE" ]]; then
        printf '检测到已有 Agent 配置。请使用 rebind 更换固定入口；重新注册需人工审查。\n' >&2
        return 30
    fi
    beszel_agent_preflight "$@" || return $?
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-beszel-agent.XXXXXX") || return 40
    candidate="$work_dir/candidate"
    mkdir "$candidate" || { rm -rf -- "$work_dir"; return 40; }
    if ! beszel_agent_fetch_release "$BESZEL_JOIN_VERSION" "$work_dir" ||
       ! beszel_agent_write_candidate "$candidate" "$BESZEL_JOIN_HUB_URL" \
           "$BESZEL_JOIN_KEY_SOURCE" "$BESZEL_JOIN_TOKEN_SOURCE"; then
        rm -rf -- "$work_dir"
        return 40
    fi
    transaction=$(beszel_agent_create_transaction) || { rm -rf -- "$work_dir"; return 40; }
    if ! beszel_agent_install_user ||
       ! install -d -m 755 "$BESZEL_AGENT_INSTALL_DIR" ||
       ! install -d -m 700 -o "$BESZEL_AGENT_USER" -g "$BESZEL_AGENT_GROUP" "$BESZEL_AGENT_DATA_DIR" ||
       ! install -d -m 710 -g "$BESZEL_AGENT_GROUP" "$BESZEL_AGENT_CONFIG_DIR" ||
       ! install -m 755 "$work_dir/beszel-agent" "$BESZEL_AGENT_BINARY" ||
       ! printf '%s\n' "$BESZEL_JOIN_VERSION" > "$BESZEL_AGENT_VERSION_FILE" ||
       ! chmod 644 "$BESZEL_AGENT_VERSION_FILE" ||
       ! install -m 600 "$candidate/agent.env" "$BESZEL_AGENT_ENV_FILE" ||
       ! install -m 600 -o "$BESZEL_AGENT_USER" -g "$BESZEL_AGENT_GROUP" \
           "$candidate/hub-key" "$BESZEL_AGENT_KEY_FILE" ||
       ! install -m 600 -o "$BESZEL_AGENT_USER" -g "$BESZEL_AGENT_GROUP" \
           "$candidate/hub-token" "$BESZEL_AGENT_TOKEN_FILE" ||
       ! install -m 644 "$candidate/service" "$BESZEL_AGENT_SERVICE_FILE"; then
        rm -rf -- "$work_dir"
        printf 'Agent 文件安装失败，正在恢复安装前状态。\n' >&2
        beszel_agent_restore_transaction "$transaction" || return 60
        return 40
    fi
    rm -rf -- "$work_dir"
    if ! systemctl daemon-reload ||
       ! systemctl enable --now "$BESZEL_AGENT_SERVICE" ||
       ! beszel_agent_verify_files ||
       ! beszel_agent_wait_active; then
        printf 'Agent 启动验证失败，正在恢复安装前状态。\n' >&2
        beszel_agent_restore_transaction "$transaction" || return 60
        return 50
    fi
    vps_set_last_transaction monitoring.beszel-agent "$transaction" || return 40
    printf 'Beszel Agent 已安装并启动，已配置固定 Hub 入口。\n'
    printf '请在中央 Hub 页面确认该 VPS 出现新的采样时间。\n'
}

beszel_agent_rebind() {
    local hub_url='' candidate transaction current
    vps_require_root || return $?
    while (( $# > 0 )); do
        case $1 in
            --hub-url) hub_url=${2:-}; shift 2 ;;
            *) printf '未知参数: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    beszel_agent_validate_hub_url "$hub_url" || return $?
    beszel_agent_verify_files || { printf 'Beszel Agent 尚未由本模块完整安装。\n' >&2; return 30; }
    current=$(beszel_agent_config_hub_url) || return 30
    [[ "$current" != "$hub_url" ]] || { printf 'Hub 地址没有变化。\n'; return 10; }
    beszel_agent_probe_hub "$hub_url" || return $?
    transaction=$(beszel_agent_create_transaction) || return 40
    candidate=$(mktemp "${TMPDIR:-/tmp}/vps-beszel-env.XXXXXX") || return 40
    awk -v url="$hub_url" 'BEGIN { done=0 }
        /^HUB_URL=/ { print "HUB_URL=" url; done=1; next }
        { print }
        END { if (!done) print "HUB_URL=" url }' "$BESZEL_AGENT_ENV_FILE" > "$candidate" || {
            rm -f -- "$candidate"; return 40;
        }
    chmod 600 "$candidate" || { rm -f -- "$candidate"; return 40; }
    install -m 600 "$candidate" "$BESZEL_AGENT_ENV_FILE" || { rm -f -- "$candidate"; return 40; }
    rm -f -- "$candidate"
    if ! systemctl restart "$BESZEL_AGENT_SERVICE" ||
       ! beszel_agent_wait_active; then
        printf '新 Hub 入口启动验证失败，正在恢复原配置。\n' >&2
        beszel_agent_restore_transaction "$transaction" || return 60
        return 50
    fi
    vps_set_last_transaction monitoring.beszel-agent "$transaction" || return 40
    printf 'Hub 入口已更新；Token、公钥和 Agent 指纹均未更改。\n'
    printf '请在中央 Hub 页面确认该 VPS 出现新的采样时间。\n'
}

beszel_agent_status() {
    local hub_url version='未知' enabled='未启用' active='未运行'
    if [[ ! -x "$BESZEL_AGENT_BINARY" ]]; then
        printf 'Beszel Agent 尚未由 VPS Secure 安装。\n'
        return 10
    fi
    [[ -r "$BESZEL_AGENT_VERSION_FILE" ]] && version=$(<"$BESZEL_AGENT_VERSION_FILE")
    hub_url=$(beszel_agent_config_hub_url 2>/dev/null || printf '配置不完整')
    systemctl is-enabled --quiet "$BESZEL_AGENT_SERVICE" 2>/dev/null && enabled='已启用'
    systemctl is-active --quiet "$BESZEL_AGENT_SERVICE" 2>/dev/null && active='运行中'
    printf 'Beszel Agent 本地状态\n\n'
    printf '版本：%s\n' "$version"
    printf 'Hub：%s\n' "$hub_url"
    printf '开机启动：%s\n' "$enabled"
    printf '服务：%s\n' "$active"
    printf '入站监听：已关闭（WebSocket 主动连接模式）\n'
    printf 'Docker/磁盘高权限：未授予\n'
    printf '\n此状态不包含 Hub 端到端在线证明；最终以 Hub 的最新采样时间为准。\n'
}

beszel_agent_start() {
    vps_require_root || return $?
    beszel_agent_verify_files || return 30
    systemctl enable --now "$BESZEL_AGENT_SERVICE" || return 40
}

beszel_agent_stop() {
    vps_require_root || return $?
    [[ -e "$BESZEL_AGENT_SERVICE_FILE" ]] || { printf 'Agent 服务尚未安装。\n'; return 10; }
    systemctl disable --now "$BESZEL_AGENT_SERVICE" || return 40
}

beszel_agent_backup() {
    local transaction
    vps_require_root || return $?
    beszel_agent_verify_files || return 30
    transaction=$(beszel_agent_create_transaction) || return 40
    vps_set_last_transaction monitoring.beszel-agent "$transaction" || return 40
    printf 'Agent 配置已保存到受保护的本地事务目录。\n'
}

beszel_agent_rollback() {
    local transaction
    vps_require_root || return $?
    transaction=$(vps_last_transaction monitoring.beszel-agent) || {
        printf '没有可恢复的 Beszel Agent 事务。\n' >&2
        return 30
    }
    beszel_agent_restore_transaction "$transaction" || return $?
    printf '已恢复上一次 Beszel Agent 修改前的状态。\n'
}

beszel_agent_uninstall() {
    local transaction
    vps_require_root || return $?
    [[ -e "$BESZEL_AGENT_BINARY" || -e "$BESZEL_AGENT_SERVICE_FILE" || -e "$BESZEL_AGENT_ENV_FILE" ]] || {
        printf 'Beszel Agent 尚未安装。\n'
        return 10
    }
    beszel_agent_unit_owned || {
        printf '服务文件不属于本模块，拒绝卸载。\n' >&2
        return 30
    }
    transaction=$(beszel_agent_create_transaction) || return 40
    systemctl disable --now "$BESZEL_AGENT_SERVICE" >/dev/null 2>&1 || true
    rm -f -- "$BESZEL_AGENT_SERVICE_FILE" "$BESZEL_AGENT_BINARY" "$BESZEL_AGENT_VERSION_FILE" \
        "$BESZEL_AGENT_ENV_FILE" "$BESZEL_AGENT_KEY_FILE" "$BESZEL_AGENT_TOKEN_FILE" || return 40
    systemctl daemon-reload || return 40
    vps_set_last_transaction monitoring.beszel-agent "$transaction" || return 40
    printf '本机 Beszel Agent 和活动凭据已移除；指纹数据和受保护回滚点已保留。\n'
    printf '中央 Hub 中的节点记录和 Token 未被修改，请在 Hub 中单独审查。\n'
}

beszel_agent_doctor() {
    beszel_agent_status || true
    printf '\n诊断边界：本模块不会输出 Token、公钥内容或完整服务日志。\n'
    beszel_agent_verify_files || return 50
}

beszel_agent_main() {
    local action=${1:-}
    shift || true
    case "$action" in
        check) beszel_agent_check ;;
        plan) beszel_agent_plan "$@" ;;
        preflight) beszel_agent_preflight "$@" ;;
        apply) beszel_agent_apply "$@" ;;
        configure) beszel_agent_rebind "$@" ;;
        verify) beszel_agent_verify ;;
        status) beszel_agent_status ;;
        backup) beszel_agent_backup ;;
        rollback) beszel_agent_rollback ;;
        start) beszel_agent_start ;;
        stop) beszel_agent_stop ;;
        uninstall) beszel_agent_uninstall ;;
        doctor) beszel_agent_doctor ;;
        *) printf 'monitoring.beszel-agent 不支持操作: %s\n' "$action" >&2; return 64 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    beszel_agent_main "$@"
fi
