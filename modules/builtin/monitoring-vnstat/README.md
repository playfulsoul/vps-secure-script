# 月度流量额度（vnStat）

在每台 VPS 分别配置网卡、套餐额度、每月重置日与两级阈值。`--quota-gb` 为十进制 GB（1 GB = 10⁹ 字节）；也可用 `--quota-gib` 指定二进制 GiB：

```bash
vps monitor traffic configure --interface eth0 --quota-gb 3072 \
  --reset-day 1 --warn-percent 80 --critical-percent 90 --yes
vps monitor traffic status
```

配置命令在缺少 vnStat 时通过系统软件包管理器安装它，确认指定网卡已被采集后写入 root-only 配置。状态命令汇总本机 vnStat JSON v2 的日字节记录，按 VPS 本地日期计算账期；重置日为 29–31 且月份较短时取该月最后一天。它不改变 vnStat 的全局 `MonthRotate`。首次安装后若本账期历史缺失，会明确标记“不完整”。上传、下载和合计是网卡计数，不保证与 VPS 服务商的账单口径相同。若 VPS 时区不是北京时间，月初切换时刻也不同；vnStat 日记录不能事后精确重算另一时区的账期。本期不提供月度额度邮件通知。
