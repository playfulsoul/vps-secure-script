# Changelog

## Unreleased

- Point the standalone 1.x migration assistant to the published and post-release-validated `2.0.0-beta.7` remote desktop release, with the public archive SHA-256 pinned in the assistant.

## 2.0.0-beta.7 - 2026-09-21

- Add a beginner-guided remote graphical desktop module with resource-aware LXQt, XFCE, and MATE profiles, optional Firefox and sudo access, ordinary-user provisioning, loopback-only xrdp over an SSH tunnel, text-only clipboard, exact package inventory, verification, and transactional rollback.
- Keep xrdp masked while distribution packages are installed, reject display managers and pre-existing unmanaged desktop stacks, and start the service only after the platform-owned loopback configuration is ready.
- Verify and drain exact xrdp service cgroups and logind desktop-session scopes before package removal; fail closed before purge when session identity or cleanup cannot be proven, including half-closed sessions.
- Point the standalone 1.x migration assistant to the published and post-release-validated `2.0.0-beta.6.1` update reliability fix, with the public archive SHA-256 pinned in the assistant.
- Run automatic CI for pull requests, `main` pushes, and `v*` version-tag pushes without duplicating runs for ordinary feature-branch pushes; retain manual CI runs.

## 2.0.0-beta.6.1 - 2026-09-13

- Point the standalone 1.x migration assistant to the published and post-release-validated `2.0.0-beta.6` firewall persistence fix.
- Separate short background GitHub metadata checks from longer, bounded user-requested update checks so slow API responses can retry without delaying every menu open.
- Cool down automatic update checks after a network failure while keeping explicit checks available immediately.
- Retry interrupted Release downloads within a fixed total time budget, resume the archive within the same update attempt, discard older partial files, and continue to require the published SHA-256 before installation.

## 2.0.0-beta.6 - 2026-09-13

- Point the standalone 1.x migration assistant to the published and post-release-validated `2.0.0-beta.5` security fix.
- Verify UFW against the active IPv4/IPv6 kernel chains instead of trusting displayed configuration alone.
- Detect competing firewall persistence services even when the current boot order happens to leave UFW working.
- Add an explicitly confirmed, backed-up persistence repair that enables UFW at boot, disables competing boot loaders without stopping them, reloads UFW, verifies the result, and supports service-state rollback without flushing the rules table.
- Warn about duplicate Fail2Ban SSH input hooks without treating them as proof that Fail2Ban caused a connectivity failure.

## 2.0.0-beta.5 - 2026-08-22

- 修复 macOS 构建的发布包在 root 直接解压时可能把 `/root` 所有者改为 `501:staff` 的问题。
- GitHub 公钥导入现在会检查并修复目标用户主目录所有者，并在验证时检查完整 SSH 路径权限。

- Point the standalone 1.x migration assistant directly to the published `2.0.0-beta.4` release.
- Add public testing and release guides, contribution/security/support policies, and structured GitHub issue and pull-request templates.
- Make the beta installation instructions work on minimal Debian/Ubuntu images without preinstalled curl and stop the command chain after the first failed step.
- Record successful Debian 13 validation for SSH port preservation, UFW, Fail2Ban, rollback, recovery, and reboot persistence.

## 2.0.0-beta.4 - 2026-08-21

- Point the standalone 1.x migration assistant directly to the now-published `2.0.0-beta.3` release.
- Rename the user-facing product to VPS 管理与安全平台 while retaining all `vps-secure` repository, command, update, and filesystem identifiers for compatibility.
- Add a color-aware, icon-based section menu with a plain-text fallback for non-interactive and `NO_COLOR` environments.
- Expand the guided VPS setup to cover UFW, Fail2Ban, optional package updates, BBR detection, and a memory-aware Swap choice.
- Make the low-load network check usable without prior timer configuration and render human-readable latency, loss, traffic, and sample-rate results.
- Validate the complete ordinary-user setup and low-load network workflow on a dedicated Ubuntu 24.04 VPS.

## 2.0.0-beta.3 - 2026-08-21

- Replace the legacy raw-script entry with a standalone 1.x-to-2.x reinstallation assistant that downloads and verifies a complete release package without changing existing VPS configuration.
- Redesign the beginner interface around concrete tasks, expose feature keywords on the first page, and pause after every result before redrawing a menu.
- Add dedicated workflows for packages, Swap, BBR, users, Docker, 1Panel, network monitoring, and VPS diagnostics while retaining technical module actions in advanced mode.
- Pin YABS, Bench.sh, RegionRestrictionCheck, NextTrace, Fusion, and IP Quality entry scripts to immutable commits with built-in SHA-256, license metadata, and non-executing preflight checks.
- Pin and verify the 1Panel official installer entry script, including a non-executing preflight, so ordinary users no longer need to provide a checksum manually.

## 2.0.0-beta.2.1 - 2026-08-21

- Remove macOS extended attributes and file flags from release archives so GNU tar on VPS hosts does not emit misleading extraction warnings.
- Add release-package regression coverage.

## 2.0.0-beta.2 - 2026-08-21

- Add a Chinese beginner dashboard and task-oriented menus.
- Add a guided VPS security initialization workflow.
- Add verified GitHub SSH public-key import with rollback.
- Add cached GitHub Release checks, verified self-update, and version restore.
- Rewrite the README around first-time installation and public-key onboarding.

## 2.0.0-beta.1 - 2026-08-21

- 将单文件脚本重构为核心加模块的平台结构。
- Debian 11/12/13 与 Ubuntu 22.04/24.04 作为首批目标系统。
- SSH 端口从当前连接和服务配置探测；无法确认时停止，不回退到 22。
- 防火墙不再默认开放 22、80、443；Fail2Ban 使用独立配置片段。
- Fail2Ban 适配 Debian journald，清除继承的文件日志路径，并支持不改系统状态的临时合并配置预检。
- Fail2Ban 启动验证会等待服务套接字就绪，避免慢启动被误判并触发回滚。
- 防火墙回滚不会删除当前 SSH 会话正在使用的端口规则；切换连接后可再次完成回滚。
- 防火墙与 Fail2Ban 的健康重复应用保留原有有效回滚点，不执行冗余服务变更。
- 系统修改统一采用预检、计划、确认、验证和事务回滚。
- 新增 APT、Swap、BBR、用户、Docker、1Panel、外部诊断模块。
- 新增低负载延迟、丢包和接口流量监控 MVP。
- 新增带 SHA-256 校验的模块安装器、发行包生成器和测试套件。
- 完成 Debian 12、Ubuntu 22.04 与 Ubuntu 24.04 真实 VPS 验收，包括 Ubuntu 24.04 默认 `ssh.socket` 和仅自定义端口重启。
