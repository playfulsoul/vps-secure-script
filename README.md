# VPS Secure Platform

一款面向普通用户的 VPS 安全与管理工具。安装后只需输入 `vps`，按照中文数字菜单操作，不需要了解 GitHub、Shell 或模块命令。

当前版本为 `2.0.0-beta.2.1`。它保留了 1.x 简单直观的菜单体验，同时使用 2.x 模块化安全内核：执行前说明变化、保留当前 SSH 端口、执行后自动验证，并为关键操作保存回滚点。

> Beta 版本已经在 Debian 12、Ubuntu 22.04 和 Ubuntu 24.04 的真实 VPS 上完成主要安全流程测试。首次使用仍建议选择有网页控制台、快照或救援模式的测试机。

## 安装后怎样使用

输入：

```bash
sudo vps
```

程序会显示服务器状态和中文菜单：

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          VPS 安全与管理平台
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
系统：Ubuntu 24.04
SSH 端口：32876（程序不会自动改成 22）
防火墙：运行正常
SSH 防暴力破解：运行正常

1. 新 VPS 安全初始化（推荐）
2. 安全防护
3. 系统管理
4. 应用安装
5. 网络监控与测试
6. 查看完整服务器检查报告
7. 更新与恢复
8. 高级模式
0. 退出
```

第一次使用建议选择 **1. 新 VPS 安全初始化**。程序会先检查系统和 SSH 端口，显示将要进行的修改，得到确认后再配置 UFW 和 Fail2Ban。

安全初始化遵守以下规则：

- 保留当前有效的 SSH 端口，不会擅自改为 22。
- 无法可靠确认 SSH 端口时停止，不冒险启用防火墙。
- 只放行确认过的 SSH 端口，不默认开放 80 或 443。
- 保留现有防火墙规则和用户配置。
- Fail2Ban 使用项目自己的配置片段，不覆盖 `jail.local`。
- 修改后自动验证；关键模块提供撤销上次修改的入口。

## 安装 beta 版本

从 GitHub Release 下载程序包和校验文件，验证无误后安装：

```bash
curl -fLO https://github.com/playfulsoul/vps-secure-script/releases/download/v2.0.0-beta.2.1/vps-secure-platform-2.0.0-beta.2.1.tar.gz
curl -fLO https://github.com/playfulsoul/vps-secure-script/releases/download/v2.0.0-beta.2.1/vps-secure-platform-2.0.0-beta.2.1.tar.gz.sha256
sha256sum -c vps-secure-platform-2.0.0-beta.2.1.tar.gz.sha256
tar -xzf vps-secure-platform-2.0.0-beta.2.1.tar.gz
sudo ./install.sh
sudo vps
```

安装和防火墙操作期间请保持当前 SSH 窗口打开。有条件时先创建 VPS 快照，并确认服务商网页控制台可用。

项目不采用 `curl | bash` 直接把远程内容交给 root 执行。

## 使用 SSH 公钥登录（推荐）

SSH 公钥登录比反复输入服务器密码更安全。可以把“公钥”理解为安装在服务器上的锁，把只保存在自己电脑中的“私钥”理解为钥匙。

### 最简单的方法：通过 GitHub 导入

### 第一步：在自己的电脑生成密钥

macOS、Linux 或 Windows PowerShell 都可以运行：

```bash
ssh-keygen -t ed25519 -C "我的电脑"
```

没有特殊要求时一路按回车即可。私钥通常是 `id_ed25519`，绝对不要发送给任何人；可以公开和上传的是带 `.pub` 后缀的 `id_ed25519.pub`。

### 第二步：把公钥添加到 GitHub

macOS 或 Linux 查看公钥：

```bash
cat ~/.ssh/id_ed25519.pub
```

Windows PowerShell 查看公钥：

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
```

复制整行内容，打开 [GitHub SSH keys 设置](https://github.com/settings/keys)，选择 **New SSH key**，粘贴并保存。

### 第三步：在 VPS 中导入

运行 `sudo vps`，依次选择：

```text
2. 安全防护
2. 从 GitHub 导入登录公钥
```

输入 GitHub 用户名和服务器用户（一般是 `root`）。程序会：

- 只从 `https://github.com/用户名.keys` 获取公开密钥；
- 验证返回内容确实是 SSH 公钥；
- 显示密钥指纹；
- 保留并去重已有公钥；
- 正确设置 `.ssh` 和 `authorized_keys` 权限；
- 保存可回滚备份。

也可以使用命令模式：

```bash
sudo vps ssh key import-github <GitHub用户名> --user root --yes
```

### 第四步：一定要测试新窗口

保持原窗口不要关闭，另外打开一个终端，用同一端口重新登录。确认无需服务器密码也能登录后，才可以考虑关闭密码登录。

当前版本导入公钥时**不会自动关闭密码登录**。这是有意的安全设计：密钥路径、客户端选择或云服务商配置稍有差异，立即关闭密码可能把用户锁在服务器外。关闭密码登录将作为独立的验证流程提供，而不会与公钥导入捆绑执行。

## 自动检查和更新

已安装用户输入 `vps` 时，程序每天最多检查一次 GitHub Release。发现新版本会在首页提示，但不会擅自更新；网络不可用也不会影响正常使用。

在菜单中选择 **7. 更新与恢复**，可以检查并安装更新。更新包必须通过 SHA-256 校验，安装器会保留上一版本备份。

命令模式：

```bash
vps update status
vps update check
sudo vps update apply --yes
sudo vps update rollback --yes
```

Beta 版本默认跟随 `beta` 通道，正式版本默认只接收 `stable` 更新。

## 功能分类

| 分类 | 普通用户功能 |
|---|---|
| 安全防护 | SSH 端口状态、GitHub 公钥导入、UFW、Fail2Ban |
| 系统管理 | 软件包更新、Swap、BBR、用户和 sudo |
| 应用安装 | Docker Engine、1Panel |
| 网络监控 | 延迟、丢包、网卡流量和外部诊断工具 |
| 平台管理 | 状态总览、自动检查更新、校验安装和版本恢复 |

高级用户仍可在主菜单进入“高级模式”，也可以直接运行模块命令：

```bash
vps module list
vps doctor
vps firewall plan
sudo vps firewall apply --yes
vps fail2ban status
```

## 模块化扩展

平台是统一入口，功能不需要全部堆进一个大型脚本。安全、系统、应用、监控和诊断能力由独立模块提供；其他项目也可以保留自己的仓库和发布节奏，再通过经过版本与摘要校验的模块包接入。

```bash
sudo vps module install https://example.org/example-module.tar.gz \
  --sha256 <64位摘要> --yes
```

模块规范见 [MODULE_SPEC.md](MODULE_SPEC.md)，技术结构见 [ARCHITECTURE.md](ARCHITECTURE.md)，兼容性范围见 [COMPATIBILITY.md](COMPATIBILITY.md)。

## 开发和测试

无需安装即可运行本地代码：

```bash
./bin/vps
./tests/run.sh
./scripts/build-release.sh
```

真实 VPS 验收记录：

- [Debian 12](docs/DEBIAN_12_VALIDATION.md)
- [Ubuntu 22.04](docs/UBUNTU_22_04_VALIDATION.md)
- [Ubuntu 24.04](docs/UBUNTU_24_04_VALIDATION.md)

旧版 `v1.0.1` 原样保存在 `legacy/v1.0.1/`，仅用于追溯，不再作为 v2 主实现。

## 许可证

本项目采用 MIT License。外部诊断工具仍分别受其上游许可证约束。
