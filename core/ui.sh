#!/usr/bin/env bash

# shellcheck source=platform.sh
source "$VPS_PLATFORM_ROOT/core/platform.sh"
# shellcheck source=ssh.sh
source "$VPS_PLATFORM_ROOT/core/ssh.sh"

vps_ui_pause() {
    [[ -t 0 ]] || return 0
    read -r -p $'\n按回车键继续……' _
}

vps_ui_show_result() {
    local title=$1 result
    shift
    printf '\n━━━━━━━━ %s ━━━━━━━━\n\n' "$title"
    "$@"
    result=$?
    printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    case "$result" in
        0) printf '[完成] 操作已完成。\n' ;;
        10) printf '[提示] 操作已结束；当前功能可能尚未配置或无需变更。\n' ;;
        90) printf '[取消] 没有执行任何修改。\n' ;;
        *) printf '[未完成] 请查看上方提示后重试。\n' ;;
    esac
    vps_ui_pause
    return 0
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
    if vps_module_action_changes_state "$action"; then
        case "$action" in
            apply|configure)
                if vps_module_declares_action "$(vps_module_find "$module_id")" plan; then
                    vps_module_run "$module_id" plan "$@" || return $?
                fi
                ;;
        esac
        printf '\n'
        vps_ui_confirm '确认执行此操作？' || { printf '已取消。\n'; return 90; }
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
    vps_ui_confirm '开始安全初始化？' || { printf '已取消，服务器没有被修改。\n'; return 90; }

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
    [[ "$answer" =~ ^[Yy]$ ]] || { printf '已取消。\n'; return 90; }
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
            1) vps_ui_show_result 'SSH 端口状态' vps_module_run security.ssh status ;;
            2) vps_ui_show_result 'GitHub 登录公钥' vps_ui_github_key ;;
            3) vps_ui_show_result '启用防火墙' vps_ui_run_action security.firewall apply ;;
            4) vps_ui_show_result '防火墙状态' vps_module_run security.firewall status ;;
            5) vps_ui_show_result '启用 SSH 防暴力破解' vps_ui_run_action security.fail2ban apply ;;
            6) vps_ui_show_result 'SSH 防护状态' vps_module_run security.fail2ban status ;;
            7) vps_ui_show_result '撤销防火墙修改' vps_ui_run_action security.firewall rollback ;;
            8) vps_ui_show_result '撤销 Fail2Ban 修改' vps_ui_run_action security.fail2ban rollback ;;
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

vps_ui_packages_menu() {
    local choice
    while true; do
        vps_ui_header
        printf '系统软件更新\n\n'
        printf '  1. 查看有多少软件可以更新\n'
        printf '  2. 更新系统软件（不升级发行版）\n'
        printf '  3. 检查 APT 是否可以正常工作\n'
        printf '  0. 返回系统管理\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_show_result '可更新软件' vps_module_run system.packages status ;;
            2) vps_ui_show_result '更新系统软件' vps_ui_run_action system.packages apply ;;
            3) vps_ui_show_result 'APT 兼容性检查' vps_module_run system.packages check ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_swap_create() {
    local size
    read -r -p '请输入 Swap 大小 [1G]: ' size
    size=${size:-1G}
    vps_ui_run_action system.swap apply --size "$size"
}

vps_ui_swap_menu() {
    local choice
    while true; do
        vps_ui_header
        printf 'Swap 虚拟内存\n\n'
        printf '  1. 查看当前 Swap 状态\n'
        printf '  2. 创建 Swap 文件\n'
        printf '  3. 撤销本工具创建的 Swap\n'
        printf '  4. 检查系统是否支持 Swap 管理\n'
        printf '  0. 返回系统管理\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_show_result 'Swap 状态' vps_module_run system.swap status ;;
            2) vps_ui_show_result '创建 Swap' vps_ui_swap_create ;;
            3) vps_ui_show_result '撤销 Swap 修改' vps_ui_run_action system.swap rollback ;;
            4) vps_ui_show_result 'Swap 兼容性检查' vps_module_run system.swap check ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_bbr_menu() {
    local choice
    while true; do
        vps_ui_header
        printf 'BBR 网络加速\n\n'
        printf '  1. 查看当前网络加速状态\n'
        printf '  2. 启用 BBR 网络加速\n'
        printf '  3. 恢复启用前的设置\n'
        printf '  4. 检查系统是否支持 BBR\n'
        printf '  0. 返回系统管理\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_show_result 'BBR 当前状态' vps_module_run system.bbr status ;;
            2) vps_ui_show_result '启用 BBR' vps_ui_run_action system.bbr apply ;;
            3) vps_ui_show_result '恢复 BBR 设置' vps_ui_run_action system.bbr rollback ;;
            4) vps_ui_show_result 'BBR 兼容性检查' vps_module_run system.bbr check ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_user_add() {
    local username
    read -r -p '请输入要创建的用户名: ' username
    [[ -n "$username" ]] || { printf '用户名不能为空。\n'; return 64; }
    vps_ui_run_action system.users configure add "$username"
}

vps_ui_user_remove() {
    local username answer delete_home=''
    read -r -p '请输入要删除的用户名: ' username
    [[ -n "$username" ]] || { printf '用户名不能为空。\n'; return 64; }
    read -r -p '是否同时删除该用户的主目录？(y/N): ' answer
    [[ "$answer" =~ ^[Yy]$ ]] && delete_home=--delete-home
    vps_ui_run_action system.users configure remove "$username" "$delete_home"
}

vps_ui_users_menu() {
    local choice
    while true; do
        vps_ui_header
        printf '用户与 sudo 权限\n\n'
        printf '  1. 查看普通用户\n'
        printf '  2. 创建 sudo 用户\n'
        printf '  3. 删除普通用户\n'
        printf '  4. 检查用户管理工具\n'
        printf '  0. 返回系统管理\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_show_result '普通用户列表' vps_module_run system.users status ;;
            2) vps_ui_show_result '创建 sudo 用户' vps_ui_user_add ;;
            3) vps_ui_show_result '删除普通用户' vps_ui_user_remove ;;
            4) vps_ui_show_result '用户管理兼容性检查' vps_module_run system.users check ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_system_menu() {
    local choice
    while true; do
        vps_ui_header
        printf '系统管理｜软件更新 · Swap · BBR · 用户与 sudo\n\n'
        printf '  1. 系统软件更新\n'
        printf '  2. Swap 虚拟内存\n'
        printf '  3. BBR 网络加速\n'
        printf '  4. 用户与 sudo 权限\n'
        printf '  0. 返回首页\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_packages_menu ;;
            2) vps_ui_swap_menu ;;
            3) vps_ui_bbr_menu ;;
            4) vps_ui_users_menu ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_docker_menu() {
    local choice
    while true; do
        vps_ui_header
        printf 'Docker 容器引擎\n\n'
        printf '  1. 查看 Docker 状态\n'
        printf '  2. 安装 Docker Engine\n'
        printf '  3. 卸载 Docker（保留容器数据）\n'
        printf '  4. 检查系统是否支持 Docker\n'
        printf '  0. 返回应用安装\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_show_result 'Docker 状态' vps_module_run applications.docker status ;;
            2) vps_ui_show_result '安装 Docker' vps_ui_run_action applications.docker apply ;;
            3) vps_ui_show_result '卸载 Docker' vps_ui_run_action applications.docker uninstall ;;
            4) vps_ui_show_result 'Docker 兼容性检查' vps_module_run applications.docker check ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_1panel_menu() {
    local choice
    while true; do
        vps_ui_header
        printf '1Panel 管理面板\n\n'
        printf '  1. 查看 1Panel 状态\n'
        printf '  2. 安装 1Panel（自动校验官方脚本）\n'
        printf '  3. 卸载 1Panel\n'
        printf '  4. 下载并校验官方安装入口（不安装）\n'
        printf '  5. 检查安装依赖\n'
        printf '  0. 返回应用安装\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_show_result '1Panel 状态' vps_module_run applications.1panel status ;;
            2) vps_ui_show_result '安装 1Panel' vps_ui_run_action applications.1panel apply ;;
            3) vps_ui_show_result '卸载 1Panel' vps_ui_run_action applications.1panel uninstall ;;
            4) vps_ui_show_result '1Panel 安装入口预检' vps_module_run applications.1panel preflight ;;
            5) vps_ui_show_result '1Panel 安装依赖检查' vps_module_run applications.1panel check ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_applications_menu() {
    local choice
    while true; do
        vps_ui_header
        printf '应用安装｜Docker · Docker Compose · 1Panel\n\n'
        printf '  1. Docker 容器引擎与 Compose\n'
        printf '  2. 1Panel 管理面板\n'
        printf '  0. 返回首页\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_docker_menu ;;
            2) vps_ui_1panel_menu ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_monitor_configure() {
    local target interval retention
    read -r -p '延迟检测目标 [1.1.1.1]: ' target
    read -r -p '采集间隔（秒）[60]: ' interval
    read -r -p '数据保留天数 [30]: ' retention
    target=${target:-1.1.1.1}
    interval=${interval:-60}
    retention=${retention:-30}
    vps_ui_run_action monitoring.network configure \
        --target "$target" --interval "$interval" --retention-days "$retention"
}

vps_ui_monitor_collect() {
    vps_ui_confirm '立即采集一次延迟、丢包和流量数据？' || return 90
    vps_module_run monitoring.network apply
}

vps_ui_monitoring_menu() {
    local choice
    while true; do
        vps_ui_header
        printf '网络状态监控｜延迟 · 丢包 · 网卡流量记录\n\n'
        printf '  1. 查看最近监控数据\n'
        printf '  2. 配置并启动定时监控\n'
        printf '  3. 立即采集一次数据\n'
        printf '  4. 启动定时监控\n'
        printf '  5. 停止定时监控\n'
        printf '  6. 检查监控服务是否正常\n'
        printf '  0. 返回首页\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_show_result '最近网络监控数据' vps_module_run monitoring.network status ;;
            2) vps_ui_show_result '配置网络监控' vps_ui_monitor_configure ;;
            3) vps_ui_show_result '采集网络数据' vps_ui_monitor_collect ;;
            4) vps_ui_show_result '启动网络监控' vps_ui_run_action monitoring.network start ;;
            5) vps_ui_show_result '停止网络监控' vps_ui_run_action monitoring.network stop ;;
            6) vps_ui_show_result '网络监控服务检查' vps_module_run monitoring.network verify ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_diagnostic_run() {
    local tool=$1 label=$2
    printf '%s 属于第三方测试代码，将以 root 权限运行。\n' "$label"
    case "$tool" in
        fusion|yabs|bench)
            printf '该测试可能产生较高 CPU、磁盘负载和网络流量。\n'
            ;;
        nexttrace)
            printf '该测试会向多个网络节点发起路由探测。\n'
            ;;
    esac
    printf '平台会验证固定入口脚本；部分工具仍会继续下载上游组件。\n\n'
    vps_ui_run_action diagnostics.external configure "$tool"
}

vps_ui_diagnostics_menu() {
    local choice
    while true; do
        vps_ui_header
        printf 'VPS 测试工具｜融合怪 · YABS · Bench · 回程路由 · 流媒体 · IP 质量\n\n'
        printf '  1. 融合怪综合测试\n'
        printf '  2. YABS CPU、磁盘与网络测试\n'
        printf '  3. Bench.sh 网络带宽测试\n'
        printf '  4. NextTrace 回程路由测试\n'
        printf '  5. 流媒体解锁检测\n'
        printf '  6. IP 地址质量检测\n'
        printf '  7. 查看第三方工具来源\n'
        printf '  0. 返回首页\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_show_result '融合怪综合测试' vps_ui_diagnostic_run fusion '融合怪' ;;
            2) vps_ui_show_result 'YABS 性能测试' vps_ui_diagnostic_run yabs 'YABS' ;;
            3) vps_ui_show_result 'Bench.sh 带宽测试' vps_ui_diagnostic_run bench 'Bench.sh' ;;
            4) vps_ui_show_result 'NextTrace 回程路由' vps_ui_diagnostic_run nexttrace 'NextTrace' ;;
            5) vps_ui_show_result '流媒体解锁检测' vps_ui_diagnostic_run media '流媒体检测' ;;
            6) vps_ui_show_result 'IP 地址质量检测' vps_ui_diagnostic_run ip-quality 'IP 质量检测' ;;
            7) vps_ui_show_result '第三方工具来源' vps_module_run diagnostics.external status ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}

vps_ui_main_menu() {
    local choice
    vps_update_notice
    while true; do
        vps_ui_status_dashboard
        [[ -z "${VPS_UPDATE_AVAILABLE:-}" ]] || printf '可更新版本：%s\n' "$VPS_UPDATE_AVAILABLE"
        printf '\n  1. 新 VPS 安全初始化\n'
        printf '     防火墙 · SSH 防暴力破解\n'
        printf '  2. SSH 与安全防护\n'
        printf '     端口 · GitHub 公钥 · UFW · Fail2Ban · 回滚\n'
        printf '  3. 系统管理\n'
        printf '     软件更新 · Swap · BBR · 用户与 sudo\n'
        printf '  4. 应用安装\n'
        printf '     Docker · Docker Compose · 1Panel\n'
        printf '  5. 网络状态监控\n'
        printf '     延迟 · 丢包 · 网卡流量记录\n'
        printf '  6. VPS 测试工具\n'
        printf '     融合怪 · YABS · Bench · 回程 · 流媒体 · IP 质量\n'
        printf '  7. 服务器完整体检\n'
        printf '     系统 · SSH · 防火墙 · Fail2Ban\n'
        printf '  8. 程序更新与恢复\n'
        printf '     检查更新 · 自动升级 · 恢复旧版\n'
        printf '  9. 高级模式\n'
        printf '     全部模块与专业操作\n'
        printf '  0. 退出\n'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) vps_ui_safe_init; vps_ui_pause ;;
            2) vps_ui_security_menu ;;
            3) vps_ui_system_menu ;;
            4) vps_ui_applications_menu ;;
            5) vps_ui_monitoring_menu ;;
            6) vps_ui_diagnostics_menu ;;
            7) vps_ui_show_result '服务器完整体检' vps_module_run system.doctor doctor ;;
            8) vps_ui_update_menu ;;
            9) interactive_advanced_menu ;;
            0) return 0 ;;
            *) printf '输入无效。\n' ;;
        esac
    done
}
