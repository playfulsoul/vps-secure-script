#!/usr/bin/env bash

# shellcheck source=platform.sh
source "$VPS_PLATFORM_ROOT/core/platform.sh"
# shellcheck source=ssh.sh
source "$VPS_PLATFORM_ROOT/core/ssh.sh"

vps_ui_pause() {
    [[ -t 0 ]] || return 0
    read -r -p $'\n按回车键返回菜单……' _
}

vps_ui_header() {
    printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    # VERSION is set by the CLI before this function is called.
    # shellcheck disable=SC2153
    printf '          VPS 安全与管理平台 %s\n' "$VERSION"
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
}

vps_ui_status_dashboard() {
    local ports='未确认' detected_ports firewall='未安装' fail2ban='未安装' platform
    platform=$(vps_platform_label 2>/dev/null || printf '未知')
    detected_ports=$(vps_require_ssh_ports 2>/dev/null || true)
    [[ -z "$detected_ports" ]] || ports=$(printf '%s\n' "$detected_ports" | paste -sd, -)
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q '^Status: active$'; then firewall='运行正常'; else firewall='未启用'; fi
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        if fail2ban-client ping >/dev/null 2>&1; then fail2ban='运行正常'; else fail2ban='未运行'; fi
    fi

    vps_ui_header
    printf '系统：%s\n' "$platform"
    printf 'SSH 端口：%s（程序不会自动改成 22）\n' "$ports"
    printf '防火墙：%s\n' "$firewall"
    printf 'SSH 防暴力破解：%s\n' "$fail2ban"
    printf '更新通道：%s\n' "$(vps_update_channel)"
}

vps_ui_confirm() {
    local prompt=$1 answer
    read -r -p "$prompt (y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

vps_ui_run_action() {
    local module_id=$1 action=$2
    shift 2
    if vps_module_action_changes_state "$action" && [[ "$action" != rollback ]]; then
        vps_module_run "$module_id" plan "$@" || return $?
        printf '\n'
        vps_ui_confirm '确认执行以上操作？' || { printf '已取消。\n'; return 0; }
    fi
    vps_module_run "$module_id" "$action" "$@"
}

vps_ui_safe_init() {
    (( EUID == 0 )) || {
        printf '安全初始化需要管理员权限。请退出后输入：sudo vps init\n' >&2
        return 30
    }
    vps_ui_header
    printf '新 VPS 安全初始化\n\n'
    vps_module_run system.doctor check || {
        printf '\n当前系统不在支持范围内，初始化尚未执行。\n' >&2
        return 20
    }
    vps_module_run system.doctor doctor || true
    vps_module_run security.firewall check || {
        printf '\n无法可靠确认 SSH 端口，初始化尚未执行。\n' >&2
        return 30
    }
    printf '\n将进行以下操作：\n'
    vps_module_run security.firewall plan || return $?
    printf '\n'
    vps_module_run security.fail2ban plan || return $?
    printf '\n保证：保留当前 SSH 端口，不覆盖已有规则，不自动开放网站端口。\n'
    vps_ui_confirm '开始安全初始化？' || { printf '已取消，服务器没有被修改。\n'; return 0; }

    printf '\n[1/2] 配置防火墙……\n'
    vps_module_run security.firewall apply || return $?
    printf '\n[2/2] 配置 SSH 防暴力破解……\n'
    if ! vps_module_run security.fail2ban apply; then
        printf 'Fail2Ban 配置失败。防火墙保持安全状态，可在“安全防护”中分别检查或回滚。\n' >&2
        return 50
    fi
    printf '\n安全初始化完成。请保持当前窗口，并新开 SSH 窗口确认可以正常登录。\n'
}

vps_ui_github_key() {
    local github_user target_user answer
    (( EUID == 0 )) || {
        printf '导入登录公钥需要管理员权限。请使用 sudo vps 后重新选择。\n' >&2
        return 30
    }
    read -r -p '请输入 GitHub 用户名: ' github_user
    read -r -p '将公钥导入哪个服务器用户？[root]: ' target_user
    target_user=${target_user:-root}
    vps_module_run security.ssh plan --github "$github_user" --user "$target_user" || return $?
    read -r -p '确认获取并导入以上账户的公开密钥？(y/N): ' answer
    [[ "$answer" =~ ^[Yy]$ ]] || { printf '已取消。\n'; return 0; }
    vps_module_run security.ssh configure --github "$github_user" --user "$target_user"
}

vps_ui_security_menu() {
    local choice
    while true; do
        vps_ui_header
        printf '安全防护\n\n'
        printf '  1. 查看 SSH 端口\n'
        printf '  2. 从 GitHub 导入登录公钥\n'
        printf '  3. 安装并启用防火墙\n'
        printf '  4. 查看防火墙状态\n'
        printf '  5. 安装并启用 SSH 防暴力破解\n'
        printf '  6. 查看 SSH 防护状态\n'
        printf '  7. 撤销上一次防火墙修改\n'
        printf '  8. 撤销上一次 Fail2Ban 修改\n'
        printf '  0. 返回\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_module_run security.ssh status; vps_ui_pause ;;
            2) vps_ui_github_key; vps_ui_pause ;;
            3) vps_ui_run_action security.firewall apply; vps_ui_pause ;;
            4) vps_module_run security.firewall status; vps_ui_pause ;;
            5) vps_ui_run_action security.fail2ban apply; vps_ui_pause ;;
            6) vps_module_run security.fail2ban status; vps_ui_pause ;;
            7) vps_ui_run_action security.firewall rollback; vps_ui_pause ;;
            8) vps_ui_run_action security.fail2ban rollback; vps_ui_pause ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_update_menu() {
    local choice
    while true; do
        vps_ui_header
        printf '更新与恢复\n\n'
        printf '当前版本：%s\n' "$VERSION"
        printf '更新通道：%s\n\n' "$(vps_update_channel)"
        printf '  1. 检查新版本\n'
        printf '  2. 更新到最新版本\n'
        printf '  3. 查看上一版本备份\n'
        printf '  4. 恢复上一版本\n'
        printf '  0. 返回\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_update_check yes || true; vps_ui_pause ;;
            2)
                vps_update_check yes || true
                if vps_ui_confirm '确认下载、校验并安装新版本？'; then
                    vps_update_apply
                    vps_ui_pause
                fi
                ;;
            3) vps_update_backup_list; vps_ui_pause ;;
            4)
                if vps_ui_confirm '确认恢复上一版本？'; then
                    vps_update_rollback
                    vps_ui_pause
                fi
                ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_friendly_module_menu() {
    local title=$1
    shift
    local entries=("$@") choice item label module_id
    while true; do
        vps_ui_header
        printf '%s\n\n' "$title"
        local index=1
        for item in "${entries[@]}"; do
            IFS='|' read -r module_id label <<< "$item"
            printf '  %s. %s\n' "$index" "$label"
            index=$((index + 1))
        done
        printf '  0. 返回\n'
        read -r -p '请选择: ' choice
        [[ "$choice" == 0 ]] && return 0
        [[ "$choice" =~ ^[0-9]+$ ]] || { printf '输入无效。\n'; continue; }
        (( choice >= 1 && choice <= ${#entries[@]} )) || { printf '输入无效。\n'; continue; }
        IFS='|' read -r module_id label <<< "${entries[choice - 1]}"
        interactive_module "$module_id" "$label"
    done
}

vps_ui_main_menu() {
    local choice
    vps_update_notice
    while true; do
        vps_ui_status_dashboard
        [[ -z "${VPS_UPDATE_AVAILABLE:-}" ]] || printf '可更新版本：%s\n' "$VPS_UPDATE_AVAILABLE"
        printf '\n  1. 新 VPS 安全初始化（推荐）\n'
        printf '  2. 安全防护\n'
        printf '  3. 系统管理\n'
        printf '  4. 应用安装\n'
        printf '  5. 网络监控与测试\n'
        printf '  6. 查看完整服务器检查报告\n'
        printf '  7. 更新与恢复\n'
        printf '  8. 高级模式\n'
        printf '  0. 退出\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_safe_init; vps_ui_pause ;;
            2) vps_ui_security_menu ;;
            3) vps_ui_friendly_module_menu '系统管理' \
                'system.packages|更新系统软件包' 'system.swap|管理 Swap' \
                'system.bbr|管理 BBR' 'system.users|管理用户与 sudo' ;;
            4) vps_ui_friendly_module_menu '应用安装' \
                'applications.docker|安装和管理 Docker' 'applications.1panel|安装和管理 1Panel' ;;
            5) vps_ui_friendly_module_menu '网络监控与测试' \
                'monitoring.network|延迟、丢包和流量监控' 'diagnostics.external|经过校验的外部诊断工具' ;;
            6) vps_module_run system.doctor doctor || true; vps_ui_pause ;;
            7) vps_ui_update_menu ;;
            8) interactive_advanced_menu ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}
