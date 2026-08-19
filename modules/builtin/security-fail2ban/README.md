# Fail2Ban SSH Protection

根据系统能力选择 systemd journal 或 SSH 日志文件，使用当前确认的全部 SSH 端口生成项目自有 jail 配置。应用前保存原配置；语法、服务启动或 jail 验证失败时恢复。
