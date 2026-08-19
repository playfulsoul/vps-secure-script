# Network Monitoring

通过 systemd timer 定时采集 ICMP 延迟、丢包和默认网卡累计流量，保存为本地 TSV 历史并按天数清理。主动互联网带宽测速不纳入定时任务，以避免流量和业务干扰。
