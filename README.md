# VPS Secure Platform

VPS Secure Platform 是面向 Debian 与 Ubuntu 的模块化服务器安全和管理工具。核心只负责系统识别、菜单、模块生命周期、确认、状态与事务；安全、系统、应用、监控和诊断能力由独立模块提供。

当前预览版本为 `2.0.0-beta.1`，已完成本地自动化测试，以及 Debian 12、Ubuntu 22.04 和 Ubuntu 24.04 真实 VPS 验收，包括 `ssh.service`/`ssh.socket`、默认/双端口/仅自定义 SSH 端口、UFW、Fail2Ban、重启持久性、幂等执行、验证和回滚。其他目标系统和剩余故障场景仍待验证，请先在有控制台和快照的临时机器上测试，不要直接部署到生产服务器。

## 关键安全规则

- 保留 VPS 当前有效的自定义 SSH 端口，不主动改成 22。
- SSH 端口无法可靠确认时停止防火墙和 Fail2Ban 配置。
- 防火墙只放行检测到的 SSH 端口，不默认开放 22、80 或 443。
- 项目配置写入自有 drop-in，不覆盖用户已有主配置。
- 修改系统状态的命令必须显式添加 `--yes`，交互菜单会再次确认。
- 第三方模块和外部脚本仅通过 HTTPS 下载，并要求 SHA-256 完整性校验；不使用 `curl | bash`。

## 当前模块

| 分类 | 模块 | 能力 |
|---|---|---|
| 安全 | `security.ssh` | 查看实际 SSH 监听端口及配置来源 |
| 安全 | `security.firewall` | 最小权限 UFW 配置、验证和回滚 |
| 安全 | `security.fail2ban` | Debian 日志后端适配、独立 jail 配置和回滚 |
| 系统 | `system.doctor` | 系统、init、SSH 与依赖预检 |
| 系统 | `system.packages` | APT 更新及保守升级 |
| 系统 | `system.swap` | Swap 创建、持久化、验证和回滚 |
| 系统 | `system.bbr` | BBR 检测、配置、验证和运行值回滚 |
| 系统 | `system.users` | 普通用户与 sudo 管理 |
| 应用 | `applications.docker` | 使用官方 APT 仓库安装 Docker Engine |
| 应用 | `applications.1panel` | 校验官方安装脚本后再执行 |
| 监控 | `monitoring.network` | 定时记录延迟、丢包及网卡累计流量 |
| 诊断 | `diagnostics.external` | 隔离运行经用户校验的第三方诊断脚本 |

## 安装 beta 发行包

从 GitHub Release 下载归档和摘要，校验后再安装；不要使用 `curl | bash`：

```bash
curl -fLO https://github.com/playfulsoul/vps-secure-script/releases/download/v2.0.0-beta.1/vps-secure-platform-2.0.0-beta.1.tar.gz
curl -fLO https://github.com/playfulsoul/vps-secure-script/releases/download/v2.0.0-beta.1/vps-secure-platform-2.0.0-beta.1.tar.gz.sha256
sha256sum -c vps-secure-platform-2.0.0-beta.1.tar.gz.sha256
tar -xzf vps-secure-platform-2.0.0-beta.1.tar.gz
sudo ./install.sh
vps --version
```

安装前请保持当前 SSH 窗口打开，并确认服务商控制台或救援模式可用。

## 本地试用

无需安装即可查看菜单和计划：

```bash
./bin/vps
./bin/vps module list
./bin/vps doctor
./bin/vps firewall plan
./bin/vps fail2ban plan
./bin/vps fail2ban preflight
```

构建发行包：

```bash
./scripts/build-release.sh
```

解压发行包后，以 root 安装：

```bash
sudo ./install.sh
vps --version
vps
```

系统变更示例：

```bash
vps module run security.firewall plan
sudo vps module run security.firewall apply --yes
sudo vps module run security.firewall verify
```

请始终先查看 `plan`。防火墙和 SSH 相关操作时保持当前 SSH 窗口打开，并在新窗口验证连接。

## 外部模块

平台本身是集成入口，功能不需要全部堆在一个脚本里。模块包必须包含一个 `module.conf` 和入口脚本；安装时需要固定摘要：

```bash
sudo vps module install https://example.org/example-module.tar.gz \
  --sha256 <64位摘要> --yes
```

这使独立项目可以保留自己的仓库、版本和发布节奏，同时通过统一菜单接入。模块契约见 [MODULE_SPEC.md](MODULE_SPEC.md)，整体结构见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 网络监控

监控模块默认只执行小规模 Ping 和读取网卡计数器，不会自动进行高流量测速：

```bash
sudo vps module run monitoring.network configure --yes \
  --target 1.1.1.1 --interval 60 --retention-days 30
sudo vps module run monitoring.network start --yes
vps module run monitoring.network status
```

历史数据默认位于 `/var/lib/vps-secure/monitoring/network/metrics.tsv`。

## 支持范围与测试

首批目标为 Debian 11/12/13 和 Ubuntu 22.04/24.04，要求 systemd 与 APT。兼容性边界见 [COMPATIBILITY.md](COMPATIBILITY.md)，真实 Debian 验收步骤见 [docs/DEBIAN_TEST_PLAN.md](docs/DEBIAN_TEST_PLAN.md)，已完成的证据见 [Debian 12](docs/DEBIAN_12_VALIDATION.md)、[Ubuntu 22.04](docs/UBUNTU_22_04_VALIDATION.md)和 [Ubuntu 24.04](docs/UBUNTU_24_04_VALIDATION.md) 验收记录。

本地运行：

```bash
./tests/run.sh
```

旧版 `v1.0.1` 原样保存在 `legacy/v1.0.1/`。根目录的 `vps_secure.sh` 仅作为过渡兼容入口，不再是 v2 的主实现。

## 许可证

本项目采用 MIT License。外部诊断工具仍分别受其上游许可证约束。
