#!/bin/bash

# ==========================================
# 颜色与全局变量
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color
VERSION_TAG="v1.0.0"

# ==========================================
# 前置检测
# ==========================================
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}错误：请使用 root 用户运行此脚本。${NC}"
  exit 1
fi

OS=""
PM_UPDATE=""
PM_INSTALL=""
FIREWALL_CMD=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    echo -e "${RED}致命错误：无法检测到当前操作系统。${NC}"
    exit 1
fi

case $OS in
    ubuntu|debian)
        PM_UPDATE="apt-get update -y && apt-get upgrade -y"
        PM_INSTALL="apt-get install -y"
        FIREWALL_CMD="ufw"
        ;;
    centos|rhel|almalinux|rocky)
        PM_UPDATE="yum update -y"
        PM_INSTALL="yum install -y"
        FIREWALL_CMD="firewalld"
        ;;
    *)
        echo -e "${RED}抱歉，目前脚本仅支持 Ubuntu/Debian/CentOS/AlmaLinux。${NC}"
        exit 1
        ;;
esac

# ==========================================
# 工具函数: 暂停与返回
# ==========================================
pause() {
    echo ""
    read -n 1 -s -r -p "按任意键继续..."
}

# ==========================================
# 工具函数: 配置文件修改
# ==========================================
set_ssh_config() {
    local key=$1
    local value=$2
    # 移除已有的配置行（无论是否被注释）并添加新配置，确保唯一性
    sed -i "/^#*$key /d" /etc/ssh/sshd_config
    echo "$key $value" >> /etc/ssh/sshd_config
}

# ==========================================
# 模块 0: 全局快捷命令注入
# ==========================================
install_shortcut() {
    if [ -x /usr/local/bin/vps ]; then
        echo -e "${GREEN}快捷命令 'vps' 已经安装过了！${NC}"
        pause
        return
    fi
    echo -e "${BLUE}正在将此工具安装为全局命令 'vps' ...${NC}"
    cp "$0" /usr/local/bin/vps
    chmod +x /usr/local/bin/vps
    echo -e "${GREEN}安装成功！以后在终端任何地方直接输入 'vps' 即可唤起本界面。${NC}"
    pause
}

# ==========================================
# 模块 1: 系统与 SSH
# ==========================================
do_system_update() {
    echo -e "${BLUE}开始更新系统及其软件包，请耐心等待...${NC}"
    eval $PM_UPDATE
    echo -e "${GREEN}系统更新完成！${NC}"
    pause
}

change_ssh_port() {
    read -p "请输入您想设置的新 SSH 端口号 [建议 20000-60000 之间]: " NEW_PORT
    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}输入无效，端口必须是 1 到 65535 之间的数字！${NC}"
        pause; return
    fi
    echo -e "${BLUE}正在准备修改 SSH 端口...${NC}"
    
    if [ "$FIREWALL_CMD" == "ufw" ]; then
        eval "$PM_INSTALL ufw > /dev/null 2>&1"
        ufw allow $NEW_PORT/tcp
    elif [ "$FIREWALL_CMD" == "firewalld" ]; then
        eval "$PM_INSTALL firewalld > /dev/null 2>&1"
        systemctl start firewalld
        firewall-cmd --permanent --add-port=$NEW_PORT/tcp
        firewall-cmd --reload
    fi
    
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    set_ssh_config "Port" "$NEW_PORT"
    systemctl restart sshd || systemctl restart ssh
    
    echo -e "${GREEN}SSH 端口已成功修改为 $NEW_PORT !${NC}"
    echo -e "${YELLOW}【警告】如果修改不连通，旧端口的终端可能随时断开。请保持当前终端不关，新开一个终端尝试连接验证！${NC}"
    pause
}

import_github_key() {
    read -p "请输入您的 GitHub 用户名: " GITHUB_USER
    if [ -z "$GITHUB_USER" ]; then echo -e "${RED}用户名不能为空！${NC}"; pause; return; fi
    
    echo -e "${BLUE}获取 GitHub 用户 $GITHUB_USER 的公钥...${NC}"
    KEYS=$(curl -sL "https://github.com/${GITHUB_USER}.keys")
    if [[ "$KEYS" == "Not Found" ]] || [[ -z "$KEYS" ]] || [[ "$KEYS" == *"<h1>"* ]]; then
        echo -e "${RED}未找到有效的公钥！请核对用户名并在GitHub挂载了公钥。${NC}"; pause; return
    fi
    
    mkdir -p ~/.ssh; chmod 700 ~/.ssh
    echo "$KEYS" >> ~/.ssh/authorized_keys
    sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    
    echo -e "${GREEN}导入公钥成功！${NC}"
    read -p "是否立刻禁用 SSH 密码登录强行使用密钥？(y/N, 强烈推荐新手开个新窗口测试连通再说): " DISABLE_PW
    if [[ "$DISABLE_PW" =~ ^[Yy]$ ]]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        
        # 核心安全设置
        set_ssh_config "PasswordAuthentication" "no"
        set_ssh_config "PubkeyAuthentication" "yes"
        set_ssh_config "KbdInteractiveAuthentication" "no"
        # 兼容旧版本
        set_ssh_config "ChallengeResponseAuthentication" "no"
        
        systemctl restart sshd || systemctl restart ssh
        echo -e "${GREEN}密码登录已禁用 (终极安全形态)！${NC}"
    else
        echo -e "${BLUE}未修改密码登录策略。${NC}"
    fi
    pause
}

# ==========================================
# 模块 2: 防火墙管理
# ==========================================
install_firewall() {
    echo -e "${BLUE}正在自动配置防火墙，并放行基本端口 (SSH, 80, 443)...${NC}"
    CUR_SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    CUR_SSH_PORT=${CUR_SSH_PORT:-22}
    
    if [ "$FIREWALL_CMD" == "ufw" ]; then
        eval "$PM_INSTALL ufw"
        ufw allow $CUR_SSH_PORT/tcp
        ufw allow 80/tcp
        ufw allow 443/tcp
        echo "y" | ufw enable
    else
        eval "$PM_INSTALL firewalld"
        systemctl enable firewalld
        systemctl start firewalld
        firewall-cmd --permanent --add-port=$CUR_SSH_PORT/tcp
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --reload
    fi
    echo -e "${GREEN}防火墙已开启并配置完毕！${NC}"
    pause
}

status_firewall() {
    echo -e "${YELLOW}>>> 当前防火墙状态与放行规则 <<<${NC}"
    if [ "$FIREWALL_CMD" == "ufw" ]; then
        ufw status verbose
    else
        firewall-cmd --list-all
    fi
    pause
}

allow_custom_port() {
    read -p "请输入想放行的端口(如 '8888' 或协议组合 '8888/tcp'): " CUSTOM_PORT
    if [ -z "$CUSTOM_PORT" ]; then return; fi
    if [[ ! "$CUSTOM_PORT" =~ "/" ]]; then CUSTOM_PORT="$CUSTOM_PORT/tcp"; fi
    
    echo -e "${BLUE}正在放行 $CUSTOM_PORT ...${NC}"
    if [ "$FIREWALL_CMD" == "ufw" ]; then
        ufw allow $CUSTOM_PORT
    else
        firewall-cmd --permanent --add-port=$CUSTOM_PORT
        firewall-cmd --reload
    fi
    echo -e "${GREEN}端口 $CUSTOM_PORT 已成功放行！${NC}"
    pause
}

reload_firewall() {
    if [ "$FIREWALL_CMD" == "ufw" ]; then ufw reload; else firewall-cmd --reload; fi
    echo -e "${GREEN}防火墙规则已重新加载！${NC}"
    pause
}

# ==========================================
# 模块 3: Fail2Ban 管理
# ==========================================
install_fail2ban() {
    echo -e "${BLUE}安装防暴力破解 Fail2Ban...${NC}"
    eval "$PM_INSTALL fail2ban"
    
    CUR_SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    CUR_SSH_PORT=${CUR_SSH_PORT:-ssh}

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = $CUR_SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}Fail2Ban 预制防护安装完成！(连续错误5次封禁1天)${NC}"
    pause
}

status_fail2ban() {
    echo -e "${YELLOW}>>> Fail2ban 服务运行状态 <<<${NC}"
    systemctl status fail2ban --no-pager | grep Active
    echo ""
    echo -e "${YELLOW}>>> 正在拦截的 IP 列表 (SSH) <<<${NC}"
    fail2ban-client status sshd 2>/dev/null || echo -e "${RED}无法获取状态，检查是否尚未安装。${NC}"
    pause
}

view_fail2ban_log() {
    echo -e "${YELLOW}>>> 查看最新拦截日志 <<<${NC}"
    tail -n 15 /var/log/fail2ban.log 2>/dev/null || echo "暂无日志文件或未安装 Fail2Ban。"
    pause
}

# ==========================================
# 模块 4: 性能加固 (BBR & Swap)
# ==========================================
enable_bbr() {
    echo -e "${BLUE}检查 BBR...${NC}"
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}BBR 网速提升机制早已开启，无需配置。${NC}"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${GREEN}BBR 网络加速开启成功！${NC}"
    fi
    pause
}

add_swap() {
    if swapon --show | grep -q "/"; then
        echo -e "${YELLOW}系统已存在 Swap 虚拟内存，退出防重复。${NC}"
    else
        echo -e "${BLUE}正在创建 1GB 虚拟内存 (防突发 OOM 崩溃)...${NC}"
        fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo -e "${GREEN}Swap 1GB 创建成功！${NC}"
    fi
    pause
}

# ==========================================
# 模块 5: 用户权限管理
# ==========================================
add_sudo_user() {
    echo -e "${YELLOW}>>> 新增具备 Sudo 权限的普通用户 <<<${NC}"
    read -p "请输入要创建的新用户名: " NEW_USER
    if [ -z "$NEW_USER" ]; then echo -e "${RED}用户名不能为空！${NC}"; pause; return; fi
    if id "$NEW_USER" &>/dev/null; then
        echo -e "${YELLOW}用户 $NEW_USER 已存在！${NC}"
        pause; return
    fi
    
    echo -e "${BLUE}正在创建普通用户 $NEW_USER ...${NC}"
    # 增加 -m 创建家目录，-s 指定 shell
    if ! useradd -m -s /bin/bash "$NEW_USER"; then
        echo -e "${RED}用户创建失败，请检查系统日志。${NC}"
        pause; return
    fi
    
    echo -e "${BLUE}请为用户 $NEW_USER 设置登录密码:${NC}"
    passwd "$NEW_USER"
    
    if [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
        usermod -aG sudo "$NEW_USER"
    else
        usermod -aG wheel "$NEW_USER"
    fi
    
    echo -e "${GREEN}用户 $NEW_USER 创建完成，并已授予最高 sudo 权限！${NC}"
    echo -e "${YELLOW}提示: 平日请使用该普通用户登录，需要系统级操作时再使用 'sudo' 命令。${NC}"
    pause
}

# 新增函数：列出普通用户（UID >= 1000 且非系统用户）
list_normal_users() {
    echo -e "${BLUE}当前系统普通用户列表:${NC}"
    awk -F: '($3>=1000 && $1!="nobody") {print $1}' /etc/passwd
    pause
}

# 新增函数：删除普通用户（安全提示）
delete_normal_user() {
    read -p "请输入要删除的普通用户名: " DEL_USER
    if [ -z "$DEL_USER" ]; then echo -e "${RED}用户名不能为空！${NC}"; pause; return; fi
    if ! id "$DEL_USER" &>/dev/null; then
        echo -e "${RED}用户 $DEL_USER 不存在！${NC}"
        pause; return
    fi
    if [ "$DEL_USER" == "root" ]; then
        echo -e "${RED}不能删除 root 用户！${NC}"
        pause; return
    fi
    echo -e "${YELLOW}警告：将删除用户 $DEL_USER 及其家目录。此操作不可恢复！${NC}"
    read -p "确认删除吗？(y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        userdel -r "$DEL_USER"
        echo -e "${GREEN}用户 $DEL_USER 已删除。${NC}"
    else
        echo -e "${BLUE}已取消删除。${NC}"
    fi
    pause
}


# ==========================================
# 模块 6: 拓展应用部署 (Docker & 1Panel)
# ==========================================
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}系统已安装了 Docker 环境，跳过安装。${NC}"
        pause; return
    fi
    echo -e "${BLUE}>>> 正在拉取 Docker 官方一键构建脚本... <<<${NC}"
    curl -fsSL https://get.docker.com | bash -s docker
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}>>> Docker 容器服务安装完成并已启动！<<<${NC}"
    pause
}

install_1panel() {
    if command -v 1pctl >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到系统已安装 1Panel，请确认是否重复安装。${NC}"
    fi
    echo -e "${BLUE}>>> 正在调用 1Panel 官方通用极速安装剧本... <<<${NC}"
    curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && sudo bash quick_start.sh
    pause
}

uninstall_1panel() {
    if ! command -v 1pctl >/dev/null 2>&1; then
        echo -e "${RED}系统未检测到 1Panel (1pctl 命令不存在)，无需卸载。${NC}"
        pause; return
    fi
    echo -e "${RED}警告：即将卸载 1Panel 面板，此操作将停止相关容器。${NC}"
    read -p "确认要执行卸载吗？(y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        1pctl uninstall
        echo -e "${GREEN}1Panel 卸载脚本已执行。${NC}"
    else
        echo -e "${BLUE}已取消卸载。${NC}"
    fi
    pause
}

uninstall_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}系统未检测到 Docker 环境，无法执行卸载。${NC}"
        pause; return
    fi
    
    echo -e "${RED}警告：卸载 Docker 将停止并删除所有正在运行的容器！${NC}"
    read -p "确认要彻底移除 Docker 引擎吗？(y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}已取消操作。${NC}"; pause; return
    fi

    echo -e "${BLUE}正在停止 Docker 服务...${NC}"
    systemctl stop docker 2>/dev/null
    
    echo -e "${BLUE}正在移除 Docker 核心组件...${NC}"
    if [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
        apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
        apt-get autoremove -y --purge
    else
        yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
    fi

    read -p "是否同时删除所有 Docker 数据 (镜像、容器、卷、/var/lib/docker)？(y/N): " DELETE_DATA
    if [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
        rm -rf /var/lib/docker
        rm -rf /etc/docker
        echo -e "${GREEN}Docker 及其数据已彻底移除。${NC}"
    else
        echo -e "${GREEN}Docker 引擎已卸载，数据已保留。${NC}"
    fi
    pause
}

# ==========================================
# 模块 7: 综合评测与监控测速
# ==========================================
view_sys_overview() {
    clear
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}        📊 实时系统性能监控概览          ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${BLUE}▶ 系统运行时间 (Uptime):${NC}"
    uptime -p
    echo ""
    echo -e "${BLUE}▶ CPU 使用及系统负载 (Load Average):${NC}"
    cat /proc/loadavg | awk '{print "近 1 分钟: "$1", 近 5 分钟: "$2", 近 15 分钟: "$3}'
    echo ""
    echo -e "${BLUE}▶ 内存与交换空间使用量 (Free -h):${NC}"
    free -h
    echo ""
    echo -e "${BLUE}▶ 磁盘剩余空间 (Disk Space):${NC}"
    df -hT | grep -E '^/dev/sda|^/dev/vda|^/dev/nvme|^/dev/root' | awk '{print "分区: "$1", 格式: "$2", 总容量: "$3", 已用: "$4", 剩余: "$5", 挂载点: "$7}'
    if [ $? -ne 0 ]; then df -hT | grep -v 'tmpfs' | grep -v 'devtmpfs'; fi
    pause
}

run_yabs() {
    echo -e "${YELLOW}【系统负载警告】综合性能压测 (Geekbench等) 将长时间占据高比例的 CPU 算力，并进行大量网络吞吐测速，低配系统 (如 512MB 内存) 易发生卡死或 OOM。${NC}"
    read -p "确认执行 YABS 性能评测脚本吗？(y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        curl -sL yabs.sh | bash
    fi
    pause
}

run_bench() {
    echo -e "${YELLOW}【流量警告】全球网络节点测速将极大地消耗双向按 G 计算的流量！如果您是按量计费用户请三思！${NC}"
    read -p "确定要运行 bench.sh 吗？(y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        curl -Lso- bench.sh | bash
    fi
    pause
}

run_media_unlock() {
    echo -e "${BLUE}>>> 正在调取流媒体解锁评测脚本 RegionRestrictionCheck... <<<${NC}"
    bash <(curl -L -s check.unlock.media)
    pause
}

run_nexttrace() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}    🛰️ 回程路由追踪工具箱     ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 基础追踪 (自定义 IP/域名)"
        echo -e "  ${YELLOW}2.${NC} 三网回程测速 (北京/上海/广州)"
        echo -e "  ${YELLOW}0.${NC} 返回上一级"
        echo
        read -p "➜ 请选择测试模式 [0-2]: " NT_CHOICE
        case $NT_CHOICE in
            1)
                read -p "请输入追踪目标 (IP 或域名): " TARGET_IP
                if [ -z "$TARGET_IP" ]; then TARGET_IP=""; fi
                # 依赖检测
                if ! command -v nexttrace >/dev/null 2>&1; then
                     echo -e "${BLUE}后台自动安装 Nexttrace 探针...${NC}"
                     curl nxtrace.org/nt | bash
                fi
                if [ -z "$TARGET_IP" ]; then
                    nexttrace --ipv4
                else
                    nexttrace "$TARGET_IP"
                fi
                pause
                ;;
            2)
                echo -e "${BLUE}正在启动三网快速追踪 (Fast Trace)...${NC}"
                if ! command -v nexttrace >/dev/null 2>&1; then
                     curl nxtrace.org/nt | bash
                fi
                nexttrace --fast-trace
                pause
                ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 各级菜单架构
# ==========================================

menu_sys_ssh() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}     ⚙️ 系统与 SSH 管理层      ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 执行系统内核与库全套更新"
        echo -e "  ${YELLOW}2.${NC} 修改 SSH 远程端口 (防扫描)"
        echo -e "  ${YELLOW}3.${NC} 导入 GitHub 公钥并禁用密码登录"
        echo -e "  ${YELLOW}0.${NC} 返回主菜单"
        echo
        read -p "➜ 此层操作指示 [0-3]: " C1
        case $C1 in
            1) do_system_update ;;
            2) change_ssh_port ;;
            3) import_github_key ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

menu_firewall() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}   🛡️ 防火墙中心 ($FIREWALL_CMD)  ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 开启防火墙 (智能放行安全端口)"
        echo -e "  ${YELLOW}2.${NC} 查看防火墙状态 (拦截/放行一览)"
        echo -e "  ${YELLOW}3.${NC} 手动放行特定端口 (搭建业务必用)"
        echo -e "  ${YELLOW}4.${NC} 重新加载/重启 防火墙"
        echo -e "  ${YELLOW}0.${NC} 返回主菜单"
        echo
        read -p "➜ 此层操作指示 [0-4]: " C2
        case $C2 in
            1) install_firewall ;;
            2) status_firewall ;;
            3) allow_custom_port ;;
            4) reload_firewall ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

menu_fail2ban() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}      🚫 防暴力破解管理层      ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 植入底层防护规则 (防SSH爆破)"
        echo -e "  ${YELLOW}2.${NC} 查看监控状态及被封禁 IP 列表"
        echo -e "  ${YELLOW}3.${NC} 查阅最近非法试探被拒日志"
        echo -e "  ${YELLOW}4.${NC} 重启防爆破服务后台"
        echo -e "  ${YELLOW}0.${NC} 返回主菜单"
        echo
        read -p "➜ 此层操作指示 [0-4]: " C3
        case $C3 in
            1) install_fail2ban ;;
            2) status_fail2ban ;;
            3) view_fail2ban_log ;;
            4) systemctl restart fail2ban; echo -e "${GREEN}重启完成。${NC}"; pause ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

menu_performance() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}      🧰 网络优化与性能层      ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 开启 BBR 网速加速"
        echo -e "  ${YELLOW}2.${NC} 添加 1GB 虚拟内存 (Swap)"
        echo -e "  ${YELLOW}0.${NC} 返回主菜单"
        echo
        read -p "➜ 此层操作指示 [0-2]: " C4
        case $C4 in
            1) enable_bbr ;;
            2) add_swap ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

menu_user_mgmt() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}      👤 用户与权限管理层      ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 增加具备 sudo 权限的普通用户"
        echo -e "  ${YELLOW}2.${NC} 查看已添加的普通用户"
        echo -e "  ${YELLOW}3.${NC} 删除普通用户"
        echo -e "  ${YELLOW}0.${NC} 返回主菜单"
        echo
        read -p "➜ 此层操作指示 [0-3]: " C5_INPUT
        case $C5_INPUT in
            1) add_sudo_user ;;
            2) list_normal_users ;;
            3) delete_normal_user ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

menu_docker() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}    🐳 Docker 引擎管理中心     ${NC}"
        echo -e "${GREEN}===============================${NC}"
        if command -v docker >/dev/null 2>&1; then
            echo -e "状态: ${GREEN}已安装${NC}"
        else
            echo -e "状态: ${RED}未发现 Docker${NC}"
        fi
        echo
        echo -e "  ${YELLOW}1.${NC} 安装 Docker 容器引擎 (官方源)"
        echo -e "  ${YELLOW}2.${NC} 卸载 Docker 容器引擎"
        echo -e "  ${YELLOW}0.${NC} 返回上一级"
        echo
        read -p "➜ 您的选择 [0-2]: " D_CHOICE
        case $D_CHOICE in
            1) install_docker ;;
            2) uninstall_docker ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

menu_1panel() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}    🛠️ 1Panel 面板管理中心     ${NC}"
        echo -e "${GREEN}===============================${NC}"
        if command -v 1pctl >/dev/null 2>&1; then
            echo -e "状态: ${GREEN}已安装${NC}"
        else
            echo -e "状态: ${RED}未发现 1Panel${NC}"
        fi
        echo
        echo -e "  ${YELLOW}1.${NC} 安装 1Panel 现代化运管面板"
        echo -e "  ${YELLOW}2.${NC} 卸载 1Panel 现代化运管面板"
        echo -e "  ${YELLOW}0.${NC} 返回上一级"
        echo
        read -p "➜ 您的选择 [0-2]: " P_CHOICE
        case $P_CHOICE in
            1) install_1panel ;;
            2) uninstall_1panel ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

menu_app_install() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}     📦 拓展应用运行环境      ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} Docker 容器引擎 (安装/卸载)"
        echo -e "  ${YELLOW}2.${NC} 1Panel 运管面板 (安装/卸载)"
        echo -e "  ${YELLOW}0.${NC} 返回主菜单"
        echo
        read -p "➜ 请选择应用 [0-2]: " CA_INPUT
        case $CA_INPUT in
            1) menu_docker ;;
            2) menu_1panel ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

menu_vps_test() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}     📈 机器全维评测与监控     ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 📊 即时硬件调度监控仪 (CPU/内存负载追踪)"
        echo -e "  ${YELLOW}2.${NC} 🥇 发烧级极限跑分与盘测 (集成 YABS 组件)"
        echo -e "  ${YELLOW}3.${NC} 🌍 全球互联测速台 (集成 bench.sh 组件)"
        echo -e "  ${YELLOW}4.${NC} 📺 顶级流媒体解锁探测仪 (检测 Netflix/Disney+等)"
        echo -e "  ${YELLOW}5.${NC} 🛰️ 网段回程路由追踪器 (集成 NextTrace 组件)"
        echo -e "  ${YELLOW}0.${NC} 返回主菜单"
        echo
        read -p "➜ 此层操作指示 [0-5]: " CT
        case $CT in
            1) view_sys_overview ;;
            2) run_yabs ;;
            3) run_bench ;;
            4) run_media_unlock ;;
            5) run_nexttrace ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        # 检测是否已经安装为简短命令 vps
        CMD_INSTALLED=""
        if [ -x /usr/local/bin/vps ]; then
            CMD_INSTALLED=" ${YELLOW}[提示: 随时敲入 'vps' 开启管家]${NC}"
        fi
        
        echo -e "${GREEN}    🎯 VPS 安全与系统统管平台 ${YELLOW}${VERSION_TAG}${NC}"
        echo -e "${GREEN}================================================${NC}"
        echo -e "${BLUE}OS: ${OS} (版本: ${VERSION}) ${NC}$CMD_INSTALLED"
        echo
        echo -e "  ${BLUE}============ 【 第一区：一键防护 / 初装向导 】 ============${NC}"
        echo -e "  ${RED}1.${NC} 🚀 [新机首选] 零基础安全加固一次性拉满"
        echo -e "      ${YELLOW}(含更新+防火墙+Fail2ban+Swap+BBR。老机若有历史配置请慎用以免冲突)${NC}"
        echo
        echo -e "  ${BLUE}============ 【 第二区：精细化单项管理 】 ==============${NC}"
        echo -e "  ${YELLOW}2.${NC} 🔑 登录管理中心    ${YELLOW}(修改 SSH 端口 / 导入证书公钥)${NC}"
        echo -e "  ${YELLOW}3.${NC} 🛡️  防火墙管理      ${YELLOW}(开/关/放行特定业务端口)${NC}"
        echo -e "  ${YELLOW}4.${NC} 🚫 防暴力破解      ${YELLOW}(查看 Fail2ban 日志与封禁黑名单)${NC}"
        echo -e "  ${YELLOW}5.${NC} 🧰 网络与性能优化  ${YELLOW}(手动装 BBR / 增加交换内存)${NC}"
        echo -e "  ${YELLOW}6.${NC} 👤 用户与权限管理  ${YELLOW}(新增带 sudo 权限的日常普通用户)${NC}"
        echo
        echo -e "  ${BLUE}============ 【 第三区：拓展部署与机器评测 】 ===========${NC}"
        echo -e "  ${YELLOW}7.${NC} 📦 建站应用部署中心 ${YELLOW}(一键安装 Docker 与 1Panel 面板)${NC}"
        echo -e "  ${YELLOW}8.${NC} 📈 机器极限评测面板 ${YELLOW}(流媒体解锁/全网测速/YABS跑分)${NC}"
        echo
        echo -e "  ${BLUE}============ 【 脚本系统维护 】 =======================${NC}"
        echo -e "  ${YELLOW}9.${NC} 🔁 注入全局命令 ${YELLOW}(安装后随时输入 'vps' 即可唤起本菜单)${NC}"
        echo -e "  ${YELLOW}0.${NC} 退出管家"
        echo
        read -p "➜ 首页指令召唤 [0-9]: " MAIN_CHOICE
        
        case $MAIN_CHOICE in
            1)
                echo -e "${YELLOW}警告：一键防护会修改系统核心组件及防火墙，强烈建议仅在新开的 VPS 上执行。${NC}"
                read -p "确认要继续执行全局一键防护吗？(y/N): " CONFIRM_ALL
                if [[ "$CONFIRM_ALL" =~ ^[Yy]$ ]]; then
                    do_system_update
                    install_firewall
                    enable_bbr
                    add_swap
                    install_fail2ban
                    echo -e "${GREEN}>>> 一键安全防护体系已全部署完毕！<<<${NC}"
                    pause
                fi
                ;;
            2) menu_sys_ssh ;;
            3) menu_firewall ;;
            4) menu_fail2ban ;;
            5) menu_performance ;;
            6) menu_user_mgmt ;;
            7) menu_app_install ;;
            8) menu_vps_test ;;
            9) install_shortcut ;;
            0) clear; echo -e "${GREEN}再见！以后可直接在终端输入 'vps' 迅速重逢。${NC}"; exit 0 ;;
            *) echo -e "${RED}输入错误！${NC}"; sleep 1 ;;
        esac
    done
}

# 启动引擎
main_menu
