#!/usr/bin/env bash

set -u

# shellcheck source=../../../core/packages.sh
source "$VPS_PLATFORM_ROOT/core/packages.sh"
# shellcheck source=../../../core/platform.sh
source "$VPS_PLATFORM_ROOT/core/platform.sh"
# shellcheck source=../../../core/runtime.sh
source "$VPS_PLATFORM_ROOT/core/runtime.sh"
# shellcheck source=../../../core/ssh.sh
source "$VPS_PLATFORM_ROOT/core/ssh.sh"

MODULE_ID=${VPS_MODULE_ID:-applications.remote-desktop}
RD_CONFIG_DIR=${VPS_REMOTE_DESKTOP_CONFIG_DIR:-/etc/vps-secure/remote-desktop}
RD_LIB_DIR=${VPS_REMOTE_DESKTOP_LIB_DIR:-/usr/local/lib/vps-secure/remote-desktop}
RD_XRDP_DROPIN=${VPS_REMOTE_DESKTOP_XRDP_DROPIN:-/etc/systemd/system/xrdp.service.d/90-vps-secure.conf}
RD_SESMAN_DROPIN=${VPS_REMOTE_DESKTOP_SESMAN_DROPIN:-/etc/systemd/system/xrdp-sesman.service.d/90-vps-secure.conf}
RD_XRDP_UNIT_PATH=${VPS_REMOTE_DESKTOP_XRDP_UNIT_PATH:-/etc/systemd/system/xrdp.service}
RD_SESMAN_UNIT_PATH=${VPS_REMOTE_DESKTOP_SESMAN_UNIT_PATH:-/etc/systemd/system/xrdp-sesman.service}
RD_XRDP_SOURCE=${VPS_REMOTE_DESKTOP_XRDP_SOURCE:-/etc/xrdp/xrdp.ini}
RD_SESMAN_SOURCE=${VPS_REMOTE_DESKTOP_SESMAN_SOURCE:-/etc/xrdp/sesman.ini}
RD_GROUP=${VPS_REMOTE_DESKTOP_GROUP:-vpsrdp}
RD_MARKER="$RD_CONFIG_DIR/managed-by-vps-secure"
RD_STATE_FILE="$RD_CONFIG_DIR/state"
RD_XRDP_ENV="$RD_CONFIG_DIR/xrdp.env"
RD_SESMAN_ENV="$RD_CONFIG_DIR/sesman.env"
RD_MEMINFO_FILE=${VPS_REMOTE_DESKTOP_MEMINFO_FILE:-/proc/meminfo}
RD_LOCAL_PORT=${VPS_REMOTE_DESKTOP_LOCAL_PORT:-13389}

RD_PROFILE=auto
RD_USER=''
RD_CREATE_USER=no
RD_GRANT_SUDO=no
RD_BROWSER=auto
RD_SET_PASSWORD=no

rd_reset_options() {
    RD_PROFILE=auto
    RD_USER=''
    RD_CREATE_USER=no
    RD_GRANT_SUDO=no
    RD_BROWSER=auto
    RD_SET_PASSWORD=no
}

rd_profile_valid() {
    [[ ${1:-} =~ ^(auto|lxqt|xfce|mate)$ ]]
}

rd_browser_valid() {
    [[ ${1:-} =~ ^(auto|none|firefox)$ ]]
}

rd_user_valid() {
    [[ ${1:-} =~ ^[a-z_][a-z0-9_-]{0,31}$ && ${1:-} != root ]]
}

rd_validate_static_settings() {
    [[ "$RD_GROUP" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$RD_GROUP" != root ]] || {
        printf '远程桌面用户组名称无效。\n' >&2
        return 64
    }
    if [[ ! "$RD_LOCAL_PORT" =~ ^[0-9]+$ ]] || \
       (( RD_LOCAL_PORT < 1024 || RD_LOCAL_PORT > 65535 || RD_LOCAL_PORT == 3389 )); then
        printf '本地隧道端口必须是 1024-65535 且不能使用 3389。\n' >&2
        return 64
    fi
}

rd_validate_managed_paths() {
    [[ ${VPS_REMOTE_DESKTOP_TEST_MODE:-no} != yes ]] || return 0
    [[ "$RD_CONFIG_DIR" == /etc/vps-secure/remote-desktop && \
       "$RD_LIB_DIR" == /usr/local/lib/vps-secure/remote-desktop && \
       "$RD_XRDP_DROPIN" == /etc/systemd/system/xrdp.service.d/90-vps-secure.conf && \
       "$RD_SESMAN_DROPIN" == /etc/systemd/system/xrdp-sesman.service.d/90-vps-secure.conf && \
       "$RD_XRDP_UNIT_PATH" == /etc/systemd/system/xrdp.service && \
       "$RD_SESMAN_UNIT_PATH" == /etc/systemd/system/xrdp-sesman.service && \
       "$RD_XRDP_SOURCE" == /etc/xrdp/xrdp.ini && \
       "$RD_SESMAN_SOURCE" == /etc/xrdp/sesman.ini ]] || {
        printf '拒绝使用非标准远程桌面管理路径。\n' >&2
        return 60
    }
}

rd_parse_options() {
    rd_reset_options
    while (( $# > 0 )); do
        case $1 in
            --profile)
                [[ $# -ge 2 ]] || return 64
                RD_PROFILE=$2
                shift 2
                ;;
            --user)
                [[ $# -ge 2 ]] || return 64
                RD_USER=$2
                shift 2
                ;;
            --create-user)
                RD_CREATE_USER=yes
                shift
                ;;
            --grant-sudo)
                RD_GRANT_SUDO=yes
                shift
                ;;
            --browser)
                [[ $# -ge 2 ]] || return 64
                RD_BROWSER=$2
                shift 2
                ;;
            --set-password)
                RD_SET_PASSWORD=yes
                shift
                ;;
            *)
                printf '未知远程桌面参数: %s\n' "$1" >&2
                return 64
                ;;
        esac
    done
    rd_profile_valid "$RD_PROFILE" || {
        printf '桌面档位无效，请使用 auto、lxqt、xfce 或 mate。\n' >&2
        return 64
    }
    rd_browser_valid "$RD_BROWSER" || {
        printf '浏览器选项无效，请使用 auto、none 或 firefox。\n' >&2
        return 64
    }
    [[ -z "$RD_USER" ]] || rd_user_valid "$RD_USER" || {
        printf '远程桌面用户名无效，且不能使用 root。\n' >&2
        return 64
    }
    rd_validate_static_settings
}

rd_memory_mb() {
    if [[ ${VPS_REMOTE_DESKTOP_MEMORY_MB:-} =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$VPS_REMOTE_DESKTOP_MEMORY_MB"
        return 0
    fi
    awk '/^MemTotal:/ { printf "%d\n", $2 / 1024; exit }' "$RD_MEMINFO_FILE"
}

rd_swap_mb() {
    if [[ ${VPS_REMOTE_DESKTOP_SWAP_MB:-} =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$VPS_REMOTE_DESKTOP_SWAP_MB"
        return 0
    fi
    awk '/^SwapTotal:/ { printf "%d\n", $2 / 1024; exit }' "$RD_MEMINFO_FILE"
}

rd_cpu_count() {
    if [[ ${VPS_REMOTE_DESKTOP_CPU_COUNT:-} =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$VPS_REMOTE_DESKTOP_CPU_COUNT"
        return 0
    fi
    nproc 2>/dev/null || getconf _NPROCESSORS_ONLN
}

rd_free_disk_mb() {
    if [[ ${VPS_REMOTE_DESKTOP_FREE_DISK_MB:-} =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$VPS_REMOTE_DESKTOP_FREE_DISK_MB"
        return 0
    fi
    df -Pm / | awk 'NR == 2 { print $4; exit }'
}

rd_recommend_profile() {
    local memory cpu free_disk
    memory=$(rd_memory_mb) || return 20
    cpu=$(rd_cpu_count) || return 20
    free_disk=$(rd_free_disk_mb) || return 20
    if (( cpu <= 1 || memory < 1536 || free_disk < 8192 )); then
        printf 'lxqt\n'
    elif (( memory < 3584 || free_disk < 15360 )); then
        printf 'xfce\n'
    else
        printf 'mate\n'
    fi
}

rd_profile_label() {
    case ${1:-} in
        lxqt) printf 'LXQt 轻量版\n' ;;
        xfce) printf 'XFCE 推荐版\n' ;;
        mate) printf 'MATE 完整版\n' ;;
        *) return 64 ;;
    esac
}

rd_profile_minimums() {
    case ${1:-} in
        lxqt) printf '768 6144\n' ;;
        xfce) printf '1536 10240\n' ;;
        mate) printf '3072 15360\n' ;;
        *) return 64 ;;
    esac
}

rd_profile_packages() {
    case ${1:-} in
        lxqt)
            printf '%s\n' lxqt-core qterminal pcmanfm-qt
            ;;
        xfce)
            printf '%s\n' xfce4 xfce4-terminal mousepad
            ;;
        mate)
            printf '%s\n' mate-desktop-environment-core mate-terminal pluma engrampa \
                mate-system-monitor fonts-noto-cjk
            ;;
        *) return 64 ;;
    esac
}

rd_browser_package() {
    local browser=$1 platform
    [[ "$browser" == firefox ]] || return 0
    platform=$(vps_platform_id 2>/dev/null || true)
    case "$platform" in
        debian) printf 'firefox-esr\n' ;;
        ubuntu) printf 'firefox\n' ;;
        *) return 20 ;;
    esac
}

rd_normalize_options() {
    [[ "$RD_PROFILE" != auto ]] || RD_PROFILE=$(rd_recommend_profile) || return $?
    if [[ "$RD_BROWSER" == auto ]]; then
        if [[ "$RD_PROFILE" == lxqt ]]; then
            RD_BROWSER=none
        else
            RD_BROWSER=firefox
        fi
    fi
}

rd_selected_packages() {
    local package
    printf '%s\n' xrdp xorgxrdp dbus-x11 x11-xserver-utils xauth policykit-1
    rd_profile_packages "$RD_PROFILE" || return $?
    rd_browser_package "$RD_BROWSER" || return $?
    [[ "$RD_GRANT_SUDO" == yes ]] && printf 'sudo\n'
    return 0
}

rd_unique_packages() {
    rd_selected_packages | awk 'NF && !seen[$0]++'
}

rd_platform_supported() {
    local platform version
    platform=$(vps_platform_id 2>/dev/null || true)
    version=$(vps_platform_version 2>/dev/null || true)
    case "$platform:$version" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) return 0 ;;
        *)
            printf '远程桌面模块不支持当前系统: %s %s。\n' \
                "${platform:-unknown}" "${version:-unknown}" >&2
            return 20
            ;;
    esac
}

rd_check_commands() {
    local command
    [[ ${VPS_REMOTE_DESKTOP_SKIP_COMMAND_CHECK:-no} != yes ]] || return 0
    for command in apt-get comm dpkg-query systemctl getent id useradd usermod groupadd \
        groupdel gpasswd passwd install awk sed sort ss; do
        command -v "$command" >/dev/null 2>&1 || {
            printf '缺少远程桌面所需命令: %s。\n' "$command" >&2
            return 20
        }
    done
    vps_has_systemd || {
        printf '远程桌面模块需要正在运行的 systemd。\n' >&2
        return 20
    }
}

rd_check() {
    local recommended memory swap cpu disk
    vps_require_apt || return $?
    rd_platform_supported || return $?
    rd_check_commands || return $?
    memory=$(rd_memory_mb) || return 20
    swap=$(rd_swap_mb) || return 20
    cpu=$(rd_cpu_count) || return 20
    disk=$(rd_free_disk_mb) || return 20
    recommended=$(rd_recommend_profile) || return $?
    printf '远程图形桌面兼容性检查通过。\n'
    printf '  系统: %s\n' "$(vps_platform_label)"
    printf '  CPU: %s 核\n' "$cpu"
    printf '  内存: %s MB\n' "$memory"
    printf '  Swap: %s MB\n' "$swap"
    printf '  根分区可用: %s MB\n' "$disk"
    printf '  推荐: %s\n' "$(rd_profile_label "$recommended")"
}

rd_state_value() {
    local key=$1 file=${2:-$RD_STATE_FILE} line
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] || continue
        printf '%s\n' "${line#*=}"
        return 0
    done < "$file"
    return 1
}

rd_is_managed() {
    [[ -f "$RD_MARKER" && -r "$RD_STATE_FILE" ]]
}

rd_package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

rd_package_present() {
    local status
    status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
    [[ -n "$status" && "$status" != 'unknown ok not-installed' ]]
}

rd_present_packages() {
    dpkg-query -W -f='${binary:Package}\t${Status}\n' 2>/dev/null |
        awk -F '\t' 'NF == 2 && $2 != "unknown ok not-installed" { print $1 }' |
        sort -u
}

rd_check_selected_package_states() {
    local package
    while IFS= read -r package; do
        if rd_package_present "$package" && ! rd_package_installed "$package"; then
            printf '软件包 %s 处于残留或未完成状态；请先修复 APT/dpkg。\n' \
                "$package" >&2
            return 30
        fi
    done < <(rd_unique_packages)
}

rd_forbidden_package_installed() {
    local package
    for package in lightdm gdm3 sddm; do
        rd_package_installed "$package" && return 0
    done
    return 1
}

rd_existing_desktop_packages() {
    local package
    for package in xrdp xorgxrdp xfce4 xfce4-session lxqt-core lxqt-session \
        mate-desktop-environment-core mate-session-manager gnome-shell plasma-desktop \
        lightdm gdm3 sddm tigervnc-standalone-server tightvncserver x11vnc \
        gnome-remote-desktop; do
        rd_package_installed "$package" && printf '%s\n' "$package"
    done
}

rd_apt_unlocked() {
    local lock
    for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
        if command -v fuser >/dev/null 2>&1 && fuser "$lock" >/dev/null 2>&1; then
            printf 'APT/dpkg 正被其他进程占用: %s\n' "$lock" >&2
            return 30
        fi
    done
}

rd_rdp_listener_state() {
    if [[ ${VPS_REMOTE_DESKTOP_LISTENER_STATE:-} =~ ^(none|loopback|public|mixed)$ ]]; then
        printf '%s\n' "$VPS_REMOTE_DESKTOP_LISTENER_STATE"
        return 0
    fi
    ss -H -ltn 2>/dev/null | awk '
        BEGIN { loopback = 0; public = 0 }
        $4 ~ /:3389$/ {
            if ($4 ~ /^127\.0\.0\.1:/ || $4 ~ /^\[::1\]:/) loopback = 1
            else public = 1
        }
        END {
            if (loopback && public) print "mixed"
            else if (public) print "public"
            else if (loopback) print "loopback"
            else print "none"
        }'
}

rd_vnc_listener_present() {
    [[ ${VPS_REMOTE_DESKTOP_VNC_LISTENER:-no} != yes ]] || return 0
    ss -H -ltn 2>/dev/null | awk '
        $4 ~ /:59[0-9][0-9]$/ { found = 1 }
        END { exit(found ? 0 : 1) }'
}

rd_check_resources() {
    local minimums min_memory min_disk memory disk
    minimums=$(rd_profile_minimums "$RD_PROFILE") || return $?
    read -r min_memory min_disk <<< "$minimums"
    memory=$(rd_memory_mb) || return 20
    disk=$(rd_free_disk_mb) || return 20
    if (( memory < min_memory )); then
        printf '%s 至少需要 %s MB 内存；当前为 %s MB。\n' \
            "$(rd_profile_label "$RD_PROFILE")" "$min_memory" "$memory" >&2
        return 30
    fi
    if (( disk < min_disk )); then
        printf '%s 至少需要 %s MB 可用磁盘；当前为 %s MB。\n' \
            "$(rd_profile_label "$RD_PROFILE")" "$min_disk" "$disk" >&2
        return 30
    fi
}

rd_check_existing_state() {
    local conflicts listeners stored_browser stored_profile stored_user unit_state
    listeners=$(rd_rdp_listener_state)
    if rd_is_managed; then
        stored_profile=$(rd_state_value profile 2>/dev/null || true)
        stored_user=$(rd_state_value user 2>/dev/null || true)
        stored_browser=$(rd_state_value browser 2>/dev/null || true)
        [[ "$RD_PROFILE" == auto || "$stored_profile" == "$RD_PROFILE" ]] || {
            printf '已安装 %s；切换桌面档位前请先卸载当前模块。\n' \
                "$(rd_profile_label "$stored_profile" 2>/dev/null || printf '%s' "$stored_profile")" >&2
            return 30
        }
        [[ -z "$RD_USER" || "$stored_user" == "$RD_USER" ]] || {
            printf '当前模块管理的桌面用户是 %s；首版不支持原地切换用户。\n' "$stored_user" >&2
            return 30
        }
        [[ "$RD_BROWSER" == auto || "$stored_browser" == "$RD_BROWSER" ]] || {
            printf '当前浏览器选项是 %s；更改软件组合前请先卸载当前模块。\n' \
                "$stored_browser" >&2
            return 30
        }
        [[ "$listeners" != public && "$listeners" != mixed ]] || {
            printf '检测到 RDP 非回环监听，拒绝继续。\n' >&2
            return 30
        }
        return 0
    fi

    conflicts=$(rd_existing_desktop_packages)
    if [[ -n "$conflicts" ]]; then
        printf '检测到未由本模块管理的桌面或远程服务，拒绝覆盖: %s\n' \
            "$(printf '%s\n' "$conflicts" | paste -sd, -)" >&2
        return 30
    fi
    if [[ "$listeners" != none ]]; then
        printf '端口 3389 已被其他服务使用，拒绝安装。\n' >&2
        return 30
    fi
    if rd_vnc_listener_present; then
        printf '检测到 VNC 监听端口，首版不会接管现有远程桌面。\n' >&2
        return 30
    fi
    if [[ -e "$RD_CONFIG_DIR" || -e "$RD_LIB_DIR" || -e "$RD_XRDP_DROPIN" || \
          -e "$RD_SESMAN_DROPIN" || -e "$RD_XRDP_UNIT_PATH" || \
          -e "$RD_SESMAN_UNIT_PATH" ]]; then
        printf '检测到没有有效管理标记的远程桌面配置，拒绝覆盖。\n' >&2
        return 30
    fi
    for unit_state in "$(rd_service_state is-enabled xrdp)" \
        "$(rd_service_state is-enabled xrdp-sesman)"; do
        [[ "$unit_state" == not-found ]] || {
            printf '检测到未由本模块管理的 xrdp systemd 单元，拒绝覆盖。\n' >&2
            return 30
        }
    done
}

rd_password_status() {
    passwd -S "$1" 2>/dev/null | awk '{ print $2; exit }'
}

rd_check_user() {
    local shell status
    [[ -n "$RD_USER" ]] || {
        printf '必须使用 --user 指定普通桌面用户。\n' >&2
        return 64
    }
    rd_user_valid "$RD_USER" || return 64
    if id "$RD_USER" >/dev/null 2>&1; then
        [[ "$RD_CREATE_USER" != yes ]] || {
            printf '用户 %s 已存在，请不要使用 --create-user。\n' "$RD_USER" >&2
            return 30
        }
        shell=$(getent passwd "$RD_USER" | awk -F: '{ print $7 }')
        case "$shell" in
            */false|*/nologin)
                printf '用户 %s 当前不能交互登录，拒绝用于远程桌面。\n' "$RD_USER" >&2
                return 30
                ;;
        esac
        if [[ "$RD_SET_PASSWORD" != yes ]]; then
            status=$(rd_password_status "$RD_USER" || true)
            [[ "$status" == P ]] || {
                printf '用户 %s 没有可用的本地密码；请使用 --set-password。\n' "$RD_USER" >&2
                return 30
            }
        fi
    else
        [[ "$RD_CREATE_USER" == yes ]] || {
            printf '用户 %s 不存在；确认新建时请添加 --create-user。\n' "$RD_USER" >&2
            return 30
        }
        [[ "$RD_SET_PASSWORD" == yes ]] || {
            printf '创建远程桌面用户时必须添加 --set-password。\n' >&2
            return 30
        }
    fi
}

rd_apt_simulate() {
    local packages=() output summary
    [[ ${VPS_REMOTE_DESKTOP_SKIP_APT_SIMULATE:-no} != yes ]] || {
        printf 'APT 模拟检查已由测试环境跳过。\n'
        return 0
    }
    while IFS= read -r package; do
        packages+=("$package")
    done < <(rd_unique_packages)
    (( ${#packages[@]} > 0 )) || return 64
    if ! output=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 install \
        --no-install-recommends "${packages[@]}" 2>&1); then
        printf 'APT 无法解析所选桌面软件包。\n%s\n' "$output" >&2
        return 30
    fi
    if printf '%s\n' "$output" | grep -Eq '^Inst (lightdm|gdm3|sddm)([ :]|$)'; then
        printf 'APT 计划包含显示管理器，违反无本地图形登录边界；拒绝继续。\n' >&2
        return 30
    fi
    summary=$(printf '%s\n' "$output" | grep -E '^[0-9]+ upgraded, ' | tail -n 1 || true)
    printf 'APT 模拟检查通过%s%s\n' "${summary:+：}" "$summary"
}

rd_plan() {
    local recommended package packages platform
    rd_parse_options "$@" || return $?
    vps_require_apt || return $?
    rd_platform_supported || return $?
    recommended=$(rd_recommend_profile) || return $?
    rd_normalize_options || return $?
    packages=''
    while IFS= read -r package; do
        packages+="${packages:+, }$package"
    done < <(rd_unique_packages)
    platform=$(vps_platform_id 2>/dev/null || true)
    printf '远程图形桌面执行计划：\n'
    printf '  - 当前推荐: %s。\n' "$(rd_profile_label "$recommended")"
    printf '  - 本次选择: %s。\n' "$(rd_profile_label "$RD_PROFILE")"
    printf '  - 桌面用户: %s。\n' "${RD_USER:-<安装时选择普通用户>}"
    printf '  - 用户处理: %s；sudo: %s；设置本地密码: %s。\n' \
        "$([[ "$RD_CREATE_USER" == yes ]] && printf '新建' || printf '使用现有')" \
        "$([[ "$RD_GRANT_SUDO" == yes ]] && printf '授予' || printf '不新增权限')" \
        "$([[ "$RD_SET_PASSWORD" == yes ]] && printf '是' || printf '否')"
    printf '  - 浏览器: %s。\n' "$RD_BROWSER"
    printf '  - 顶层软件包: %s。\n' "$packages"
    printf '  - xrdp 仅监听 127.0.0.1:3389，通过 SSH 隧道连接。\n'
    printf '  - 禁止 root 图形登录，只允许 %s 组。\n' "$RD_GROUP"
    printf '  - 不开放防火墙端口，不修改 SSH、Fail2Ban 或默认启动目标。\n'
    printf '  - 不安装显示管理器；磁盘、打印和音频重定向默认关闭。\n'
    printf '  - 卸载和回滚保留普通用户、主目录和浏览器资料。\n'
    if [[ "$platform" == ubuntu && "$RD_BROWSER" == firefox ]]; then
        printf '  - Ubuntu 的 firefox 软件包会使用发行版 Snap 机制，确认后才安装。\n'
    fi
}

rd_preflight() {
    local default_target current_ports
    rd_parse_options "$@" || return $?
    vps_require_apt || return $?
    rd_platform_supported || return $?
    rd_check_commands || return $?
    rd_normalize_options || return $?
    rd_apt_unlocked || return $?
    rd_check_resources || return $?
    rd_check_existing_state || return $?
    rd_check_user || return $?
    rd_check_selected_package_states || return $?
    current_ports=$(vps_require_ssh_ports 2>/dev/null || true)
    [[ -n "$current_ports" ]] || {
        printf '无法可靠确认当前 SSH 监听端口，拒绝进入安装阶段。\n' >&2
        return 30
    }
    rd_apt_simulate || return $?
    default_target=$(systemctl get-default 2>/dev/null || printf 'unknown')
    printf '远程图形桌面预检通过。\n'
    printf '  将保留 SSH 端口: %s。\n' "$(printf '%s\n' "$current_ports" | paste -sd, -)"
    printf '  将保留 systemd 默认目标: %s。\n' "$default_target"
    printf '  当前 RDP 监听: %s。\n' "$(rd_rdp_listener_state)"
}

rd_ini_set() {
    local file=$1 section=$2 key=$3 value=$4 temporary
    [[ -f "$file" ]] || return 1
    temporary="$file.tmp.$$"
    awk -v wanted_section="$section" -v wanted_key="$key" -v wanted_value="$value" '
        BEGIN {
            target = "[" tolower(wanted_section) "]"
            in_section = 0
            section_seen = 0
            key_written = 0
        }
        function add_key_if_needed() {
            if (in_section && !key_written) {
                print wanted_key "=" wanted_value
                key_written = 1
            }
        }
        /^\[[^]]+\][[:space:]]*$/ {
            add_key_if_needed()
            in_section = (tolower($0) == target)
            if (in_section) section_seen = 1
            print
            next
        }
        {
            if (in_section && $0 ~ "^[[:space:]]*" wanted_key "[[:space:]]*=") {
                if (!key_written) print wanted_key "=" wanted_value
                key_written = 1
                next
            }
            print
        }
        END {
            add_key_if_needed()
            if (!section_seen) {
                print ""
                print "[" wanted_section "]"
                print wanted_key "=" wanted_value
            }
        }
    ' "$file" > "$temporary" || { rm -f -- "$temporary"; return 1; }
    chmod --reference="$file" "$temporary" 2>/dev/null || chmod 644 "$temporary"
    chown --reference="$file" "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file"
}

rd_write_session_script() {
    local destination=$1 command desktop desktop_lower
    case "$RD_PROFILE" in
        lxqt) command=startlxqt; desktop=LXQt ;;
        xfce) command=startxfce4; desktop=XFCE ;;
        mate) command=mate-session; desktop=MATE ;;
        *) return 64 ;;
    esac
    desktop_lower=$(printf '%s' "$desktop" | tr '[:upper:]' '[:lower:]')
    cat > "$destination" <<EOF
#!/usr/bin/env bash
set -u

unset DBUS_SESSION_BUS_ADDRESS
unset SESSION_MANAGER
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=$desktop
export XDG_SESSION_DESKTOP=$desktop_lower
export DESKTOP_SESSION=$desktop_lower

if command -v dbus-run-session >/dev/null 2>&1; then
    exec dbus-run-session -- $command
fi
exec $command
EOF
    chmod 755 "$destination"
}

rd_prepare_owned_config() {
    install -d -m 755 "$RD_CONFIG_DIR" "$RD_LIB_DIR" || return 40
    install -m 644 "$RD_XRDP_SOURCE" "$RD_CONFIG_DIR/xrdp.ini" || return 40
    install -m 644 "$RD_SESMAN_SOURCE" "$RD_CONFIG_DIR/sesman.ini" || return 40

    rd_ini_set "$RD_CONFIG_DIR/xrdp.ini" Globals port 'tcp://127.0.0.1:3389' || return 40
    rd_ini_set "$RD_CONFIG_DIR/xrdp.ini" Channels rdpdr false || return 40
    rd_ini_set "$RD_CONFIG_DIR/xrdp.ini" Channels rdpsnd false || return 40
    rd_ini_set "$RD_CONFIG_DIR/xrdp.ini" Channels cliprdr true || return 40
    rd_ini_set "$RD_CONFIG_DIR/xrdp.ini" Channels rail false || return 40
    rd_ini_set "$RD_CONFIG_DIR/xrdp.ini" Channels xrdpvr false || return 40

    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Globals EnableUserWindowManager false || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Globals DefaultWindowManager \
        "$RD_LIB_DIR/startwm.sh" || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Globals EnableUserWindowManager false || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Security AllowRootLogin false || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Security MaxLoginRetry 3 || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Security TerminalServerUsers "$RD_GROUP" || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Security AlwaysGroupCheck true || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Security RestrictInboundClipboard file,image || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Security RestrictOutboundClipboard file,image || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Sessions MaxSessions 2 || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Sessions KillDisconnected true || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Sessions DisconnectedTimeLimit 3600 || return 40
    rd_ini_set "$RD_CONFIG_DIR/sesman.ini" Sessions IdleTimeLimit 14400 || return 40

    rd_write_session_script "$RD_LIB_DIR/startwm.sh" || return 40
    printf 'XRDP_OPTIONS="--config %s"\n' "$RD_CONFIG_DIR/xrdp.ini" > "$RD_XRDP_ENV" || return 40
    printf 'SESMAN_OPTIONS="--config %s"\n' "$RD_CONFIG_DIR/sesman.ini" > "$RD_SESMAN_ENV" || return 40
    printf '%s\n' 'applications.remote-desktop' > "$RD_MARKER" || return 40
    chmod 644 "$RD_XRDP_ENV" "$RD_SESMAN_ENV" "$RD_MARKER"
}

rd_write_systemd_dropins() {
    install -d -m 755 "$(dirname -- "$RD_XRDP_DROPIN")" \
        "$(dirname -- "$RD_SESMAN_DROPIN")" || return 40
    cat > "$RD_XRDP_DROPIN" <<EOF
# Managed by vps-secure applications.remote-desktop
[Service]
EnvironmentFile=$RD_XRDP_ENV
EOF
    cat > "$RD_SESMAN_DROPIN" <<EOF
# Managed by vps-secure applications.remote-desktop
[Service]
EnvironmentFile=$RD_SESMAN_ENV
EOF
    chmod 644 "$RD_XRDP_DROPIN" "$RD_SESMAN_DROPIN"
}

rd_confirm_no_rdp_listener() {
    local listener
    listener=$(rd_rdp_listener_state)
    [[ "$listener" == none ]] || {
        printf '安装准备期间检测到意外 RDP 监听: %s；拒绝继续。\n' "$listener" >&2
        return 40
    }
}

rd_wait_for_loopback_listener() {
    local attempt listener
    local attempts=${VPS_REMOTE_DESKTOP_LISTENER_ATTEMPTS:-20}
    local delay=${VPS_REMOTE_DESKTOP_LISTENER_DELAY:-0.25}
    if [[ ! "$attempts" =~ ^[0-9]+$ ]] || (( attempts < 1 || attempts > 120 )); then
        printf 'RDP 监听等待次数配置无效。\n' >&2
        return 50
    fi
    for (( attempt = 1; attempt <= attempts; attempt++ )); do
        listener=$(rd_rdp_listener_state)
        case "$listener" in
            loopback) return 0 ;;
            public|mixed)
                printf 'RDP 启动期间检测到非回环监听: %s。\n' "$listener" >&2
                return 50
                ;;
        esac
        (( attempt == attempts )) || sleep "$delay"
    done
    printf 'RDP 服务启动后未在限定时间内建立回环监听。\n' >&2
    return 50
}

rd_mask_units_for_install() {
    systemctl mask xrdp.service xrdp-sesman.service >/dev/null 2>&1 || {
        printf '无法在安装软件包前屏蔽 xrdp 服务。\n' >&2
        return 40
    }
    systemctl stop xrdp.service xrdp-sesman.service >/dev/null 2>&1 || true
    rd_confirm_no_rdp_listener
}

rd_unmask_units_for_start() {
    systemctl unmask xrdp.service xrdp-sesman.service >/dev/null 2>&1 || {
        printf '无法解除 xrdp 服务安装保护。\n' >&2
        return 40
    }
    systemctl daemon-reload || return 40
}

rd_text_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{ print $1 }'
    else
        shasum -a 256 | awk '{ print $1 }'
    fi
}

rd_ufw_hash() {
    if ! command -v ufw >/dev/null 2>&1; then
        printf 'absent\n'
    else
        LC_ALL=C ufw status 2>/dev/null | rd_text_hash
    fi
}

rd_service_state() {
    local operation=$1 service=$2 state
    state=$(systemctl "$operation" "$service" 2>/dev/null || true)
    [[ -n "$state" ]] || state=not-found
    printf '%s\n' "$state"
}

rd_transaction_value() {
    local transaction=$1 key=$2 line
    [[ -r "$transaction/metadata" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] || continue
        printf '%s\n' "${line#*=}"
        return 0
    done < "$transaction/metadata"
    return 1
}

rd_backup_path() {
    local transaction=$1 label=$2 path=$3
    mkdir -p "$transaction/files" || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        cp -a -- "$path" "$transaction/files/$label" || return 1
        printf '%s=present\n' "$label" >> "$transaction/paths"
    else
        printf '%s=absent\n' "$label" >> "$transaction/paths"
    fi
}

rd_path_state() {
    local transaction=$1 label=$2 line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$label="* ]] || continue
        printf '%s\n' "${line#*=}"
        return 0
    done < "$transaction/paths"
    return 1
}

rd_restore_path() {
    local transaction=$1 label=$2 path=$3 state
    state=$(rd_path_state "$transaction" "$label") || return 1
    rm -rf -- "$path" || return 1
    if [[ "$state" == present ]]; then
        mkdir -p "$(dirname -- "$path")" || return 1
        cp -a -- "$transaction/files/$label" "$path" || return 1
    fi
}

rd_create_transaction() {
    local transaction group_existed=no user_existed=no user_group=no user_sudo=no
    local ssh_ports default_target
    transaction=$(vps_new_transaction_dir "$MODULE_ID") || return 40
    : > "$transaction/paths"
    : > "$transaction/packages.present.before"
    : > "$transaction/packages.new"
    chmod 600 "$transaction/paths" "$transaction/packages.present.before" \
        "$transaction/packages.new"

    rd_backup_path "$transaction" config "$RD_CONFIG_DIR" || return 40
    rd_backup_path "$transaction" lib "$RD_LIB_DIR" || return 40
    rd_backup_path "$transaction" xrdp-dropin "$RD_XRDP_DROPIN" || return 40
    rd_backup_path "$transaction" sesman-dropin "$RD_SESMAN_DROPIN" || return 40
    rd_backup_path "$transaction" xrdp-unit "$RD_XRDP_UNIT_PATH" || return 40
    rd_backup_path "$transaction" sesman-unit "$RD_SESMAN_UNIT_PATH" || return 40

    getent group "$RD_GROUP" >/dev/null 2>&1 && group_existed=yes
    if id "$RD_USER" >/dev/null 2>&1; then
        user_existed=yes
        id -nG "$RD_USER" | tr ' ' '\n' | grep -Fxq "$RD_GROUP" && user_group=yes
        id -nG "$RD_USER" | tr ' ' '\n' | grep -Fxq sudo && user_sudo=yes
    fi
    ssh_ports=$(vps_require_ssh_ports 2>/dev/null | sort -n | paste -sd, -)
    default_target=$(systemctl get-default 2>/dev/null || printf 'unknown')
    cat > "$transaction/metadata" <<EOF
profile=$RD_PROFILE
user=$RD_USER
browser=$RD_BROWSER
group=$RD_GROUP
create_user=$RD_CREATE_USER
grant_sudo=$RD_GRANT_SUDO
user_existed=$user_existed
user_group=$user_group
user_sudo=$user_sudo
group_existed=$group_existed
xrdp_enabled=$(rd_service_state is-enabled xrdp)
xrdp_active=$(rd_service_state is-active xrdp)
xrdp_sesman_enabled=$(rd_service_state is-enabled xrdp-sesman)
xrdp_sesman_active=$(rd_service_state is-active xrdp-sesman)
default_target=$default_target
ssh_ports=$ssh_ports
ufw_hash=$(rd_ufw_hash)
fail2ban_active=$(rd_service_state is-active fail2ban)
panel_active=$(rd_service_state is-active 1panel)
EOF
    chmod 600 "$transaction/metadata"
    rd_present_packages > "$transaction/packages.present.before" || return 40
    printf '%s\n' "$transaction"
}

rd_record_new_packages() {
    local transaction=$1 current new
    current="$transaction/packages.present.current"
    new="$transaction/packages.new.tmp.$$"
    if ! rd_present_packages > "$current" || \
       ! comm -13 "$transaction/packages.present.before" "$current" > "$new"; then
        rm -f -- "$current" "$new"
        : > "$transaction/package-inventory-failed"
        return 40
    fi
    mv -f -- "$new" "$transaction/packages.new" || {
        rm -f -- "$current" "$new"
        : > "$transaction/package-inventory-failed"
        return 40
    }
    rm -f -- "$current"
    chmod 600 "$transaction/packages.new" || return 40
    rm -f -- "$transaction/package-inventory-failed"
}

rd_install_user_access() {
    if ! getent group "$RD_GROUP" >/dev/null 2>&1; then
        groupadd --system "$RD_GROUP" || return 40
    fi
    if ! id "$RD_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$RD_USER" || return 40
    fi
    if [[ "$RD_CREATE_USER" == yes || "$RD_SET_PASSWORD" == yes ]]; then
        [[ -t 0 ]] || {
            printf '设置桌面密码需要交互终端。\n' >&2
            return 30
        }
        printf '请为桌面用户 %s 设置本地登录密码。密码不会显示或写入日志。\n' "$RD_USER"
        passwd "$RD_USER" || return 40
    fi
    usermod -aG "$RD_GROUP" "$RD_USER" || return 40
    if [[ "$RD_GRANT_SUDO" == yes ]]; then
        usermod -aG sudo "$RD_USER" || return 40
    fi
}

rd_write_state() {
    local transaction=$1 owned_packages
    owned_packages=$(paste -sd, "$transaction/packages.new" 2>/dev/null || true)
    cat > "$RD_STATE_FILE.tmp.$$" <<EOF
profile=$RD_PROFILE
user=$RD_USER
browser=$RD_BROWSER
group=$RD_GROUP
installed_at=$(vps_timestamp)
transaction=$transaction
owned_packages=$owned_packages
EOF
    chmod 600 "$RD_STATE_FILE.tmp.$$" || return 40
    mv -f "$RD_STATE_FILE.tmp.$$" "$RD_STATE_FILE" || return 40
}

rd_validate_owned_config() {
    local expected_group=${1:-$RD_GROUP}
    grep -Fxq 'port=tcp://127.0.0.1:3389' "$RD_CONFIG_DIR/xrdp.ini" || return 50
    grep -Fxq 'rdpdr=false' "$RD_CONFIG_DIR/xrdp.ini" || return 50
    grep -Fxq 'rdpsnd=false' "$RD_CONFIG_DIR/xrdp.ini" || return 50
    grep -Fxq 'cliprdr=true' "$RD_CONFIG_DIR/xrdp.ini" || return 50
    grep -Fxq 'AllowRootLogin=false' "$RD_CONFIG_DIR/sesman.ini" || return 50
    grep -Fxq "TerminalServerUsers=$expected_group" "$RD_CONFIG_DIR/sesman.ini" || return 50
    grep -Fxq 'AlwaysGroupCheck=true' "$RD_CONFIG_DIR/sesman.ini" || return 50
    grep -Fxq 'EnableUserWindowManager=false' "$RD_CONFIG_DIR/sesman.ini" || return 50
    grep -Fxq "DefaultWindowManager=$RD_LIB_DIR/startwm.sh" \
        "$RD_CONFIG_DIR/sesman.ini" || return 50
    [[ -x "$RD_LIB_DIR/startwm.sh" ]] || return 50
    grep -Fxq "XRDP_OPTIONS=\"--config $RD_CONFIG_DIR/xrdp.ini\"" "$RD_XRDP_ENV" || return 50
    grep -Fxq "SESMAN_OPTIONS=\"--config $RD_CONFIG_DIR/sesman.ini\"" "$RD_SESMAN_ENV" || return 50
    grep -Fxq "EnvironmentFile=$RD_XRDP_ENV" "$RD_XRDP_DROPIN" || return 50
    grep -Fxq "EnvironmentFile=$RD_SESMAN_ENV" "$RD_SESMAN_DROPIN" || return 50
}

rd_verify_baseline() {
    local transaction=$1 before current
    before=$(rd_transaction_value "$transaction" default_target)
    current=$(systemctl get-default 2>/dev/null || printf 'unknown')
    [[ "$before" == "$current" ]] || {
        printf 'systemd 默认启动目标发生了意外变化。\n' >&2
        return 50
    }
    before=$(rd_transaction_value "$transaction" ssh_ports)
    current=$(vps_require_ssh_ports 2>/dev/null | sort -n | paste -sd, -)
    [[ -n "$current" && "$before" == "$current" ]] || {
        printf 'SSH 监听端口发生了意外变化。\n' >&2
        return 50
    }
    before=$(rd_transaction_value "$transaction" ufw_hash)
    current=$(rd_ufw_hash)
    [[ "$before" == "$current" ]] || {
        printf 'UFW 状态发生了意外变化。\n' >&2
        return 50
    }
    before=$(rd_transaction_value "$transaction" fail2ban_active)
    current=$(rd_service_state is-active fail2ban)
    [[ "$before" == "$current" ]] || {
        printf 'Fail2Ban 服务状态发生了意外变化。\n' >&2
        return 50
    }
    before=$(rd_transaction_value "$transaction" panel_active)
    current=$(rd_service_state is-active 1panel)
    [[ "$before" == "$current" ]] || {
        printf '1Panel 服务状态发生了意外变化。\n' >&2
        return 50
    }
}

rd_verify() {
    local user group listener
    rd_is_managed || {
        printf '远程图形桌面尚未由本模块配置。\n' >&2
        return 50
    }
    user=$(rd_state_value user) || return 50
    group=$(rd_state_value group) || return 50
    [[ "$group" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$group" != root ]] || return 50
    systemctl is-active --quiet xrdp || return 50
    systemctl is-active --quiet xrdp-sesman || return 50
    listener=$(rd_rdp_listener_state)
    [[ "$listener" == loopback ]] || {
        printf 'RDP 监听不符合仅回环要求: %s。\n' "$listener" >&2
        return 50
    }
    id "$user" >/dev/null 2>&1 || return 50
    id -nG "$user" | tr ' ' '\n' | grep -Fxq "$group" || return 50
    rd_validate_owned_config "$group" || return 50
    printf '远程图形桌面验证通过：服务正常、RDP 仅回环监听、root 被禁止、用户组有效。\n'
}

rd_restore_service_state() {
    local transaction=$1 service=$2 enabled active
    enabled=$(rd_transaction_value "$transaction" "${service//-/_}_enabled" 2>/dev/null || true)
    active=$(rd_transaction_value "$transaction" "${service//-/_}_active" 2>/dev/null || true)
    systemctl list-unit-files "$service.service" >/dev/null 2>&1 || return 0
    case "$enabled" in
        enabled|enabled-runtime) systemctl enable "$service" >/dev/null 2>&1 || return 1 ;;
        masked) systemctl mask "$service" >/dev/null 2>&1 || return 1 ;;
        masked-runtime) systemctl mask --runtime "$service" >/dev/null 2>&1 || return 1 ;;
        disabled|not-found|'') systemctl disable "$service" >/dev/null 2>&1 || true ;;
    esac
    case "$active" in
        active) systemctl start "$service" >/dev/null 2>&1 || return 1 ;;
        *) systemctl stop "$service" >/dev/null 2>&1 || true ;;
    esac
}

rd_restore_transaction() {
    local transaction=$1 package packages=() user group group_existed user_group user_sudo
    local grant_sudo result=0
    rd_validate_managed_paths || return $?
    [[ "$transaction" == "$(vps_module_state_dir "$MODULE_ID")"/transactions/* && \
       -d "$transaction" ]] || {
        printf '拒绝使用模块状态目录之外的事务。\n' >&2
        return 60
    }
    [[ ! -e "$transaction/rolled_back" ]] || {
        printf '该事务已经回滚。\n'
        return 10
    }
    user=$(rd_transaction_value "$transaction" user)
    group=$(rd_transaction_value "$transaction" group)
    group_existed=$(rd_transaction_value "$transaction" group_existed)
    user_group=$(rd_transaction_value "$transaction" user_group)
    user_sudo=$(rd_transaction_value "$transaction" user_sudo)
    grant_sudo=$(rd_transaction_value "$transaction" grant_sudo)
    rd_user_valid "$user" || {
        printf '事务中的远程桌面用户无效，拒绝继续回滚。\n' >&2
        return 60
    }
    [[ "$group" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$group" != root ]] || {
        printf '事务中的远程桌面用户组无效，拒绝继续回滚。\n' >&2
        return 60
    }
    systemctl stop xrdp >/dev/null 2>&1 || true
    systemctl stop xrdp-sesman >/dev/null 2>&1 || true
    systemctl mask xrdp.service xrdp-sesman.service >/dev/null 2>&1 || result=1

    rd_restore_path "$transaction" xrdp-dropin "$RD_XRDP_DROPIN" || result=1
    rd_restore_path "$transaction" sesman-dropin "$RD_SESMAN_DROPIN" || result=1
    rd_restore_path "$transaction" config "$RD_CONFIG_DIR" || result=1
    rd_restore_path "$transaction" lib "$RD_LIB_DIR" || result=1
    systemctl daemon-reload >/dev/null 2>&1 || result=1

    [[ -f "$transaction/packages.new" ]] || result=1
    if [[ -s "$transaction/packages.new" ]]; then
        while IFS= read -r package; do
            if [[ "$package" =~ ^[a-zA-Z0-9.+:-]+$ ]]; then
                packages+=("$package")
            else
                result=1
            fi
        done < "$transaction/packages.new"
        if (( ${#packages[@]} > 0 )); then
            DEBIAN_FRONTEND=noninteractive apt-get purge -y --no-auto-remove \
                "${packages[@]}" >/dev/null || result=1
        fi
    fi
    [[ ! -e "$transaction/package-inventory-failed" ]] || result=1
    rd_restore_path "$transaction" xrdp-unit "$RD_XRDP_UNIT_PATH" || result=1
    rd_restore_path "$transaction" sesman-unit "$RD_SESMAN_UNIT_PATH" || result=1
    systemctl daemon-reload >/dev/null 2>&1 || result=1
    rd_restore_service_state "$transaction" xrdp-sesman || result=1
    rd_restore_service_state "$transaction" xrdp || result=1

    if id "$user" >/dev/null 2>&1; then
        if [[ "$user_group" != yes ]]; then
            gpasswd -d "$user" "$group" >/dev/null 2>&1 || true
        fi
        if [[ "$grant_sudo" == yes && "$user_sudo" != yes ]]; then
            gpasswd -d "$user" sudo >/dev/null 2>&1 || true
        fi
    fi
    if [[ "$group_existed" != yes ]] && getent group "$group" >/dev/null 2>&1; then
        if [[ -z "$(getent group "$group" | awk -F: '{ print $4 }')" ]]; then
            groupdel "$group" >/dev/null 2>&1 || result=1
        fi
    fi

    if ! rd_verify_baseline "$transaction"; then
        result=1
    fi
    (( result == 0 )) || return 60
    : > "$transaction/rolled_back"
    chmod 600 "$transaction/rolled_back"
    if [[ $(rd_transaction_value "$transaction" user_existed) != yes ]]; then
        printf '已保留安装期间创建的用户 %s 及其主目录；没有删除用户数据。\n' "$user"
    fi
    printf '远程图形桌面模块变更已回滚。未执行 apt autoremove。\n'
}

rd_apply_failure() {
    local transaction=$1 code=$2
    trap - INT TERM
    printf '安装未完成，正在恢复模块配置和服务状态。\n' >&2
    if ! rd_restore_transaction "$transaction"; then
        printf '自动回滚未完整通过，请保留当前 SSH 会话并运行 doctor。\n' >&2
        return 60
    fi
    return "$code"
}

rd_apply_interrupted() {
    local transaction=$1
    trap - INT TERM
    printf '\n远程桌面安装被中断，正在尝试安全回滚。\n' >&2
    rd_restore_transaction "$transaction" || \
        printf '中断后的自动回滚未完整通过；请保持 SSH 会话并运行 doctor。\n' >&2
    exit 130
}

rd_apply() {
    local transaction packages=() package
    vps_require_root || return $?
    rd_validate_managed_paths || return $?
    rd_parse_options "$@" || return $?
    if rd_is_managed; then
        rd_check_existing_state || return $?
        if rd_verify; then
            printf '远程图形桌面已经处于受管且健康的状态。\n'
            return 10
        fi
        printf '现有受管安装未通过验证；请先运行 doctor 或 rollback。\n' >&2
        return 30
    fi
    rd_normalize_options || return $?
    rd_preflight "$@" || return $?
    transaction=$(rd_create_transaction) || return $?
    vps_set_last_transaction "$MODULE_ID" "$transaction" || return 40
    trap 'rd_apply_interrupted "$transaction"' INT TERM
    while IFS= read -r package; do
        packages+=("$package")
    done < <(rd_unique_packages)

    rd_mask_units_for_install || { rd_apply_failure "$transaction" 40; return $?; }
    vps_apt_update || { rd_apply_failure "$transaction" 40; return $?; }
    vps_apt_install --no-install-recommends "${packages[@]}" || {
        rd_record_new_packages "$transaction" || true
        rd_apply_failure "$transaction" 40
        return $?
    }
    rd_record_new_packages "$transaction" || {
        rd_apply_failure "$transaction" 40
        return $?
    }
    rd_confirm_no_rdp_listener || { rd_apply_failure "$transaction" 40; return $?; }
    if rd_forbidden_package_installed; then
        printf '安装结果包含显示管理器，正在回滚。\n' >&2
        rd_apply_failure "$transaction" 40
        return $?
    fi
    [[ -f "$RD_XRDP_SOURCE" && -f "$RD_SESMAN_SOURCE" ]] || {
        rd_apply_failure "$transaction" 40
        return $?
    }
    rd_prepare_owned_config || { rd_apply_failure "$transaction" 40; return $?; }
    rd_write_systemd_dropins || { rd_apply_failure "$transaction" 40; return $?; }
    rd_install_user_access || { rd_apply_failure "$transaction" 40; return $?; }
    rd_write_state "$transaction" || { rd_apply_failure "$transaction" 40; return $?; }
    rd_unmask_units_for_start || { rd_apply_failure "$transaction" 40; return $?; }
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify xrdp.service xrdp-sesman.service >/dev/null 2>&1 || {
            rd_apply_failure "$transaction" 30
            return $?
        }
    fi
    systemctl enable xrdp || { rd_apply_failure "$transaction" 40; return $?; }
    systemctl start xrdp-sesman || { rd_apply_failure "$transaction" 40; return $?; }
    systemctl start xrdp || { rd_apply_failure "$transaction" 40; return $?; }
    if ! rd_wait_for_loopback_listener; then
        rd_apply_failure "$transaction" 50
        return $?
    fi
    if ! rd_verify; then
        rd_apply_failure "$transaction" 50
        return $?
    fi
    if ! rd_verify_baseline "$transaction"; then
        rd_apply_failure "$transaction" 50
        return $?
    fi
    trap - INT TERM
    printf '远程图形桌面安装完成：%s，用户 %s。\n' \
        "$(rd_profile_label "$RD_PROFILE")" "$RD_USER"
    printf 'RDP 没有对公网开放；请查看“远程连接方法”建立 SSH 隧道。\n'
}

rd_connection_help() {
    local ssh_user ssh_host ssh_port connection
    ssh_user=${SUDO_USER:-${USER:-<SSH用户>}}
    ssh_host='<服务器地址>'
    ssh_port='<SSH端口>'
    connection=${SSH_CONNECTION:-}
    if [[ -n "$connection" ]]; then
        read -r _ _ ssh_host ssh_port <<< "$connection"
    fi
    printf '安全连接分两步：\n\n'
    printf '第一步：在自己的电脑运行并保持窗口打开：\n'
    printf 'ssh -N -L 127.0.0.1:%s:127.0.0.1:3389 -p %s %s@%s\n\n' \
        "$RD_LOCAL_PORT" "$ssh_port" "$ssh_user" "$ssh_host"
    printf '第二步：打开远程桌面客户端，连接：127.0.0.1:%s\n' "$RD_LOCAL_PORT"
    printf '桌面用户名：%s\n' "$(rd_state_value user 2>/dev/null || printf '<桌面用户>')"
    printf 'Windows：使用系统“远程桌面连接”。\n'
    printf 'macOS：使用 Windows App。\n'
    printf 'Linux：使用 Remmina 或 FreeRDP。\n'
    printf 'SSH 隧道窗口关闭后桌面会断开，但服务器文件不会丢失。\n'
}

rd_status() {
    local profile user browser listener active enabled
    if ! rd_is_managed; then
        printf '远程图形桌面未由本模块安装。\n'
        return 10
    fi
    profile=$(rd_state_value profile)
    user=$(rd_state_value user)
    browser=$(rd_state_value browser)
    listener=$(rd_rdp_listener_state)
    active=$(rd_service_state is-active xrdp)
    enabled=$(rd_service_state is-enabled xrdp)
    printf '远程图形桌面状态：\n'
    printf '  档位: %s\n' "$(rd_profile_label "$profile")"
    printf '  用户: %s\n' "$user"
    printf '  浏览器: %s\n' "$browser"
    printf '  xrdp: %s / 开机状态 %s\n' "$active" "$enabled"
    printf '  RDP 监听: %s（必须为 loopback）\n' "$listener"
    case "$listener" in
        loopback) printf '  公网 3389: 未配置\n' ;;
        none) printf '  公网 3389: 无监听\n' ;;
        *) printf '  公网 3389: 检测到危险监听，请立即运行 doctor\n' ;;
    esac
    if [[ ${1:-} == --connection ]]; then
        printf '\n'
        rd_connection_help
    fi
}

rd_doctor() {
    local result=0
    rd_status || result=$?
    if (( result == 10 )); then
        rd_check || return $?
        if ! rd_check_existing_state; then
            printf '检查结论：发现未受管或未完成的远程桌面状态，请先清理冲突。\n' >&2
            return 50
        fi
        return 0
    fi
    if rd_verify; then
        printf '检查结论：受管配置健康，无需修复。\n'
        return 0
    fi
    printf '检查结论：受管配置存在异常。请保留 SSH 会话，不要开放公网 RDP；\n' >&2
    printf '可先运行 rollback 恢复，再重新安装。\n' >&2
    return 50
}

rd_rollback() {
    local transaction
    vps_require_root || return $?
    transaction=$(vps_last_transaction "$MODULE_ID") || {
        printf '没有可用的远程桌面回滚事务。\n' >&2
        return 60
    }
    rd_restore_transaction "$transaction"
}

rd_uninstall() {
    vps_require_root || return $?
    if ! rd_is_managed; then
        printf '远程图形桌面未由本模块安装。\n'
        return 10
    fi
    rd_rollback
}

rd_main() {
    local action=${1:-}
    shift || true
    case "$action" in
        check) rd_check ;;
        plan) rd_plan "$@" ;;
        preflight) rd_preflight "$@" ;;
        apply) rd_apply "$@" ;;
        verify) rd_verify ;;
        status) rd_status "$@" ;;
        rollback) rd_rollback ;;
        uninstall) rd_uninstall ;;
        doctor) rd_doctor ;;
        *)
            printf 'applications.remote-desktop 不支持操作: %s\n' "$action" >&2
            return 64
            ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    rd_main "$@"
fi
