# Changelog

## Unreleased

- Point the standalone 1.x migration assistant directly to the now-published `2.0.0-beta.3` release.

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
