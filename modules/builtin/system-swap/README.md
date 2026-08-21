# Swap File Management

按需创建可配置大小的 Swap 文件。检测到现有 Swap 或未知目标文件时不会覆盖；创建前验证磁盘空间并保留安全余量，应用前备份 fstab，并支持回滚本模块创建的文件。
