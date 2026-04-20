#!/bin/bash

# ==========================================
# 颜色与全局变量
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color
VERSION_TAG="v1.0.1"
REPO_RAW_URL="https://raw.githubusercontent.com/playfulsoul/vps-secure-script/main/vps_secure.sh"

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
# 工具函数: 绘制进度条
# ==========================================
draw_bar() {
    local label=$1
    local percentage=$2
    local color=""
    if [ $percentage -lt 50 ]; then color=$GREEN; elif [ $percentage -lt 80 ]; then color=$YELLOW; else color=$RED; fi
    local bar_len=25
    local filled=$(( percentage * bar_len / 100 ))
    local empty=$(( bar_len - filled ))
    printf "  %-12s ${BLUE}[" "$label"
    for ((i=0; i<filled; i++)); do printf "${color}■${NC}"; done
    for ((i=0; i<empty; i++)); do printf " "; done
    printf "${BLUE}] ${color}${percentage}%%${NC}\n"
}

# ==========================================
# 模块 0: 全局快捷命令注入
# ==========================================
install_shortcut() {
    # 检测是否已经存在
    if [ -L /usr/local/bin/vps ] || [ -f /usr/local/bin/vps ]; then
        echo -e "${YELLOW}警告：检测到已存在 'vps' 命令。正在尝试升级为软链接模式...${NC}"
        rm -f /usr/local/bin/vps
    fi
    
    echo -e "${BLUE}正在将此工具安装为全局快捷命令 (软链接模式)...${NC}"
    ln -sf "$(readlink -f "$0")" /usr/local/bin/vps
    chmod +x /usr/local/bin/vps
    
    if [ -x /usr/local/bin/vps ]; then
        echo -e "${GREEN}安装成功！以后在终端任何地方直接输入 'vps' 即可唤起本界面。${NC}"
        echo -e "${YELLOW}提示: 软链接模式下，只要你更新了此目录下的脚本文件，全局命令也会自动同步。${NC}"
    else
        echo -e "${RED}安装失败，请检查 /usr/local/bin 权限。${NC}"
    fi
    pause
}

# ==========================================
# 模块 0.1: 自助检查更新
# ==========================================
check_update() {
    echo -e "${BLUE}正在从 GitHub 检查最新版本...${NC}"
    REMOTE_VERSION=$(curl -sL "$REPO_RAW_URL" | grep 'VERSION_TAG=' | head -n 1 | cut -d '"' -f 2)
    
    if [ -z "$REMOTE_VERSION" ]; then
        echo -e "${RED}无法获取远程版本信息，请确认网络是否连通 GitHub。${NC}"
        pause
        return
    fi

    if [ "$VERSION_TAG" == "$REMOTE_VERSION" ]; then
        echo -e "${GREEN}当前已是最新版本 ($VERSION_TAG)。${NC}"
        pause
    else
        echo -e "${YELLOW}检测到新版本: $REMOTE_VERSION (当前: $VERSION_TAG)${NC}"
        read -p "是否立即升级？(y/N): " CONFIRM_UPDATE
        if [[ "$CONFIRM_UPDATE" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}正在下载并更新代码...${NC}"
            curl -sL "$REPO_RAW_URL" -o "$0"
            echo -e "${GREEN}升级成功！即将重新启动脚本...${NC}"
            sleep 2
            exec bash "$0"
        fi
    fi
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
        echo -e "${GREEN}SSH 密码登录已禁用。${NC}"
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
# 模块 7: 系统监控制与基准测试
# ==========================================
view_sys_overview() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}        📊 系统实时状态监控屏            ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    
    # 系统运行时间
    echo -e "${GREEN}▶ 系统运行时间 (Uptime):${NC} $(uptime -p)"
    echo ""

    # CPU 负载计算
    echo -e "${GREEN}▶ 核心负载资源监控:${NC}"
    local cpu_load=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' | awk '{printf "%.0f", $1}')
    draw_bar "CPU 负载" "$cpu_load"

    # 内存使用率
    local mem_total=$(free | grep Mem | awk '{print $2}')
    local mem_used=$(free | grep Mem | awk '{print $3}')
    local mem_per=$(( mem_used * 100 / mem_total ))
    draw_bar "物理内存占有" "$mem_per"

    # 磁盘占用率
    local disk_per=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    draw_bar "系统磁盘挂载" "$disk_per"

    echo ""
    echo -e "${GREEN}▶ 系统平均负载 (Load Average):${NC}"
    cat /proc/loadavg | awk '{print "  1min: "$1", 5min: "$2", 15min: "$3}'
    
    echo ""
    echo -e "${GREEN}▶ 网络接口统计:${NC}"
    if command -v ip >/dev/null; then
        ip -4 -br addr | grep -v "127.0.0.1" | awk '{print "  " $1 ": " $3}'
    fi
    pause
}

run_fusion_monster() {
    echo -e "${YELLOW}警告：融合怪全能脚本将执行多项系统与网络基准测试，持续时间较长。${NC}"
    read -p "确认执行该测试吗？(y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        curl -L https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh -o ecs.sh && chmod +x ecs.sh && bash ecs.sh
    fi
    pause
}

run_ip_check() {
    echo -e "${BLUE}正在执行 IP 地址质量与风险评分检测 (基于个人纯净版)...${NC}"
    bash <(curl -Ls https://raw.githubusercontent.com/playfulsoul/IPQuality/main/ip.sh)
    pause
}

run_yabs() {
    echo -e "${YELLOW}【系统负载警告】综合性能压测 (Geekbench等) 将产生高 CPU 负载与网络吞吐，低配机型可能卡死。${NC}"
    read -p "确认执行 YABS 性能测试吗？(y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        curl -sL yabs.sh | bash
    fi
    pause
}

run_bench() {
    echo -e "${YELLOW}【流量提示】全球网络节点测速将消耗流量。${NC}"
    read -p "确定要运行 bench.sh 吗？(y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        curl -Lso- bench.sh | bash
    fi
    pause
}

run_media_unlock() {
    echo -e "${BLUE}正在调用流媒体解锁检测脚本...${NC}"
    bash <(curl -L -s check.unlock.media)
    pause
}

run_nexttrace() {
    while true; do
        clear
        echo -e "${GREEN}===============================${NC}"
        echo -e "${GREEN}      路由追踪管理           ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 基础追踪 (自定义 IP/域名)"
        echo -e "  ${YELLOW}2.${NC} 三网回程测速"
        echo -e "  ${YELLOW}0.${NC} 返回上一级"
        echo
        read -p "➜ 请选择测试模式 [0-2]: " NT_CHOICE
        case $NT_CHOICE in
            1)
                read -p "请输入追踪目标 (IP 或域名): " TARGET_IP
                if [ -z "$TARGET_IP" ]; then TARGET_IP=""; fi
                # 依赖检测
                if ! command -v nexttrace >/dev/null 2>&1; then
                     echo -e "${BLUE}后台自动安装 Nexttrace...${NC}"
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
                echo -e "${BLUE}正在执行三网快速路由追踪...${NC}"
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
        echo -e "${GREEN}       SSH 与 登录管理        ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 系统内核与库更新"
        echo -e "  ${YELLOW}2.${NC} 修改 SSH 端口"
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
        echo -e "${GREEN}       防火墙管理中心         ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 开启防火墙"
        echo -e "  ${YELLOW}2.${NC} 查看防火墙状态"
        echo -e "  ${YELLOW}3.${NC} 手动放行端口"
        echo -e "  ${YELLOW}4.${NC} 重启防火墙"
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
        echo -e "${GREEN}       Fail2Ban 安全防御      ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 植入防护规则"
        echo -e "  ${YELLOW}2.${NC} 查看监控状态及封禁 IP"
        echo -e "  ${YELLOW}3.${NC} 查看非法试探日志"
        echo -e "  ${YELLOW}4.${NC} 重启服务"
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
        echo -e "${GREEN}       网络与性能优化         ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 开启 BBR 加速"
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
        echo -e "${GREEN}       用户与权限管理         ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 增加 sudo 普通用户"
        echo -e "  ${YELLOW}2.${NC} 查看普通用户"
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
        echo -e "${GREEN}       Docker 容器引擎管理    ${NC}"
        echo -e "${GREEN}===============================${NC}"
        if command -v docker >/dev/null 2>&1; then
            echo -e "状态: ${GREEN}已安装${NC}"
        else
            echo -e "状态: ${RED}未发现 Docker${NC}"
        fi
        echo
        echo -e "  ${YELLOW}1.${NC} 安装 Docker 容器引擎"
        echo -e "  ${YELLOW}2.${NC} 卸载 Docker 容器引擎"
        echo -e "  ${YELLOW}0.${NC} 返回上一级"
        echo
        read -p "➜ 请选择操作 [0-2]: " D_CHOICE
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
        echo -e "${GREEN}       1Panel 运维面板管理    ${NC}"
        echo -e "${GREEN}===============================${NC}"
        if command -v 1pctl >/dev/null 2>&1; then
            echo -e "状态: ${GREEN}已安装${NC}"
        else
            echo -e "状态: ${RED}未发现 1Panel${NC}"
        fi
        echo
        echo -e "  ${YELLOW}1.${NC} 安装 1Panel 运维面板"
        echo -e "  ${YELLOW}2.${NC} 卸载 1Panel 运维面板"
        echo -e "  ${YELLOW}0.${NC} 返回上一级"
        echo
        read -p "➜ 请选择操作 [0-2]: " P_CHOICE
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
        echo -e "${GREEN}       系统监控与基准测试      ${NC}"
        echo -e "${GREEN}===============================${NC}"
        echo -e "  ${YELLOW}1.${NC} 📊 实时系统状态监控 (CPU/内存/磁盘)"
        echo -e "  ${YELLOW}2.${NC} 🥇 CPU 与 磁盘性能基准测试 (YABS)"
        echo -e "  ${YELLOW}3.${NC} 🌍 网络带宽基准测试 (Bench.sh)"
        echo -e "  ${YELLOW}4.${NC} 📺 流媒体解锁能力检测"
        echo -e "  ${YELLOW}5.${NC} 🛰️ 回程路由追踪 (NextTrace)"
        echo -e "  ${YELLOW}6.${NC} 🏅 综合系统评测 (Fusion Monster)"
        echo -e "  ${YELLOW}7.${NC} 🛡️ IP 地址质量检测"
        echo -e "  ${YELLOW}0.${NC} 返回主菜单"
        echo
        read -p "➜ 请选择测试项目 [0-7]: " CT
        case $CT in
            1) view_sys_overview ;;
            2) run_yabs ;;
            3) run_bench ;;
            4) run_media_unlock ;;
            5) run_nexttrace ;;
            6) run_fusion_monster ;;
            7) run_ip_check ;;
            0) break ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 模块 8: 卸载管理
# ==========================================
uninstall_script() {
    echo -e "${RED}警告：即将卸载 VPS 安全与系统管理平台并将快捷命令 'vps' 移除。${NC}"
    read -p "确认执行卸载吗？(y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        rm -f /usr/local/bin/vps
        echo -e "${GREEN}快捷命令 'vps' 已成功移除。${NC}"
        echo -e "${YELLOW}提示: 此操作仅删除了快捷命令，您原始下载的脚本文件仍保留在当前目录。${NC}"
        pause
        exit 0
    else
        echo -e "${BLUE}已取消卸载。${NC}"
        pause
    fi
}

main_menu() {
    while true; do
        clear
        # 检测是否已经安装为简短命令 vps
        CMD_INSTALLED=""
        if [ -x /usr/local/bin/vps ]; then
            CMD_INSTALLED=" ${YELLOW}[提示: 输入 'vps' 即可唤起工具]${NC}"
        fi
        
        echo -e "${GREEN}    🎯 VPS 安全与系统管理平台 ${YELLOW}${VERSION_TAG}${NC}"
        echo -e "${GREEN}================================================${NC}"
        echo -e "${BLUE}OS: ${OS} (版本: ${VERSION}) ${NC}$CMD_INSTALLED"
        echo
        echo -e "  ${BLUE}============ 【 第一区：一键配置 / 初始化 】 ============${NC}"
        echo -e "  ${RED}1.${NC} 🚀 系统基础安全加固 (更新/防火墙/BBR/Swap)"
        echo -e "      ${YELLOW}(适用于纯净系统，含内核优化、基本防护规则与虚拟内存配置)${NC}"
        echo
        echo -e "  ${BLUE}============ 【 第二区：系统单项配置 】 ==============${NC}"
        echo -e "  ${YELLOW}2.${NC} 🔑 SSH 与 登录管理"
        echo -e "  ${YELLOW}3.${NC} 🛡️ 防火墙规则管理"
        echo -e "  ${YELLOW}4.${NC} 🚫 Fail2Ban 安全拦截"
        echo -e "  ${YELLOW}5.${NC} 🧰 网络与系统优化"
        echo -e "  ${YELLOW}6.${NC} 👤 用户与权限管理"
        echo
        echo -e "  ${BLUE}============ 【 第三区：应用部署与性能评测 】 ===========${NC}"
        echo -e "  ${YELLOW}7.${NC} 📦 应用环境部署 (Docker/1Panel)"
        echo -e "  ${YELLOW}8.${NC} 📈 系统性能与网络评测"
        echo
        echo -e "  ${BLUE}============ 【 工具维护 】 =======================${NC}"
        echo -e "  ${YELLOW}9.${NC} 🔁 注入全局别名 (安装后直接输入 'vps' 启动)"
        echo -e "  ${YELLOW}10.${NC} ❌ 卸载本工具"
        echo -e "  ${YELLOW}11.${NC} 🔄 检查更新与自助升级"
        echo -e "  ${YELLOW}0.${NC} 退出程序"
        echo
        read -p "➜ 请选择项目 [0-11]: " MAIN_CHOICE
        
        case $MAIN_CHOICE in
            1)
                echo -e "${YELLOW}警告：一键加固将修改防火墙与系统核心参数。${NC}"
                read -p "确认执行系统安全加固吗？(y/N): " CONFIRM_ALL
                if [[ "$CONFIRM_ALL" =~ ^[Yy]$ ]]; then
                    do_system_update
                    install_firewall
                    enable_bbr
                    add_swap
                    install_fail2ban
                    echo -e "${GREEN}系统基础安全防护配置完成。${NC}"
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
            10) uninstall_script ;;
            11) check_update ;;
            0) clear; echo -e "${GREEN}程序已退出。${NC}"; exit 0 ;;
            *) echo -e "${RED}输入错误！${NC}"; sleep 1 ;;
        esac
    done
}

# 启动引擎
main_menu
