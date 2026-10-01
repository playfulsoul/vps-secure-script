# Beszel Hub Backup and Restore

管理已经安装并由 systemd 运行的 Beszel Hub。本模块不安装、升级或公开 Hub，也不配置 DNS、反向代理、隧道或云盘。

默认路径和服务可通过以下变量覆盖：

- `VPS_BESZEL_HUB_SERVICE`：systemd 服务名，默认 `beszel.service`
- `VPS_BESZEL_HUB_DATA_DIR`：持久数据目录，默认 `/var/lib/beszel/beszel_data`
- `VPS_BESZEL_HUB_BACKUP_DIR`：本地备份目录
- `VPS_BESZEL_HUB_STATE_DIR`：恢复事务与目标原数据快照目录
- `VPS_BESZEL_HUB_HEALTH_URL`：本机健康检查地址，默认 `http://127.0.0.1:8090/api/health`

`backup` 会记录服务原状态；若 Hub 正在运行，则先停服，再把完整数据目录和格式清单写入归档，生成 SHA-256 摘要，最后恢复原运行状态。备份及摘要默认仅 root 可读。

`apply --archive <文件>` 用于恢复。默认读取 `<文件>.sha256`，也可通过 `--checksum-file <文件>` 或 `--sha256 <摘要>` 指定预期摘要。恢复前会校验摘要、归档路径、文件类型和格式清单，并拒绝链接及特殊文件。目标数据会先保存到模块事务目录；新数据只从同一文件系统的 staging 目录切换。重启后最多等待 20 秒通过本机健康检查；启动或健康验证失败时自动恢复原数据。

`configure --remote <crypt远端> --path <逻辑目录>` 会创建新的离线迁移包，通过以 OneDrive 为底层的 rclone crypt 远端上传归档和摘要，再下载两者并校验 SHA-256，最后重新验证 Hub。它不会挂载 OneDrive，也不会删除任一副本。

`start --remote <crypt远端> [--path scheduled] [--time 04:30] [--timezone Asia/Shanghai]` 会安装并启用模块所有的 persistent systemd timer。每天执行的服务复用上述完整回读验证流程，并加入最多 10 分钟随机延迟；启用定时器本身不会立即创建备份。`doctor onedrive-schedule` 显示配置、定时器和上次服务结果，`stop` 只停用定时器并保留配置及全部备份。成功完成回读和健康验证的副本会取得受保护的验证记录；`doctor onedrive-retention` 检查 30 天、至少 7 份的保留条件及本地和云端副本完整性，只提供预览。当前没有自动删除策略。

备份失败检查器位于 `scripts/beszel-backup-watchdog.sh`，对应的 systemd 单元模板位于 `scripts/vps-secure-beszel-backup-watchdog.service`。安装者需将脚本放到单元声明的 `/usr/local/libexec/vps-secure-beszel-backup-watchdog`，再启用该单元。它只读取上次备份结果、文件新鲜度、定时器状态和备份服务结果，不读取 rclone 凭据，也不执行备份。最近一次成功结果超过 28 小时、备份失败或定时器停用时，常驻服务退出并保持 failed；可由 Beszel Agent 的 `SERVICE_PATTERNS=vps-secure-beszel-backup-watchdog.service` 和 Hub 的失败服务规则监测。故障排除并取得新的成功备份后，需要手动重启看护服务以解除锁存的失败状态。`vps monitor hub onedrive-health` 可只读查看同类健康条件。

如果 Hub 位于反向代理或隧道后，Beszel 服务应设置 `APP_URL` 为用户访问的 HTTPS 根地址，否则告警邮件中的链接可能指向 `localhost`。`status` 只读显示该地址或提示缺失；本模块不会自动修改现有 Hub 服务的环境变量。

备份包含 Hub 密钥、账户和监测历史，必须按凭据材料保护。不要把实时数据目录放在 Google Drive、OneDrive、NFS 或 rclone 挂载目录中；云端只适合作为加密备份的副本。
