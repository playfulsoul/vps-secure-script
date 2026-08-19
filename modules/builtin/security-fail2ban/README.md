# Fail2Ban SSH Protection

根据系统能力选择 systemd journal 或 SSH 日志文件，使用当前确认的全部 SSH 端口生成项目自有 jail 配置。`preflight` 会复制现有配置到临时目录，合并候选配置并调用 Fail2Ban 自身校验，不修改 `/etc` 或服务状态。应用前保存原配置；语法、服务启动或 jail 验证失败时恢复。
