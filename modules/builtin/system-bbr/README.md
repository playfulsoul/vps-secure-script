# BBR Congestion Control

仅在内核明确提供 BBR 时写入项目自有 sysctl 配置，应用后验证实际算法，失败时恢复原配置。
