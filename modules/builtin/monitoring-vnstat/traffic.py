#!/usr/bin/env python3
"""Render a VPS billing cycle from vnStat v2 daily byte counters."""

import argparse
import calendar
import datetime as dt
import json
import os
import sys


def anchor(year: int, month: int, reset_day: int) -> dt.date:
    return dt.date(year, month, min(reset_day, calendar.monthrange(year, month)[1]))


def previous_month(year: int, month: int) -> tuple[int, int]:
    return (year - 1, 12) if month == 1 else (year, month - 1)


def next_month(year: int, month: int) -> tuple[int, int]:
    return (year + 1, 1) if month == 12 else (year, month + 1)


def record_date(value: dict) -> dt.date:
    return dt.date(int(value["year"]), int(value["month"]), int(value["day"]))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--interface", required=True)
    quota_group = parser.add_mutually_exclusive_group(required=True)
    quota_group.add_argument("--quota-gib", type=int)
    quota_group.add_argument("--quota-gb", type=int)
    parser.add_argument("--reset-day", type=int, required=True)
    parser.add_argument("--warn-percent", type=int, required=True)
    parser.add_argument("--critical-percent", type=int, required=True)
    args = parser.parse_args()
    try:
        data = json.load(sys.stdin)
        if str(data.get("jsonversion")) != "2":
            raise ValueError("仅支持以字节输出的 vnStat JSON v2")
        matches = [item for item in data["interfaces"] if item.get("name") == args.interface]
        if len(matches) != 1:
            raise ValueError("vnStat 输出中没有唯一匹配的网卡")
        item = matches[0]
        today = dt.date.fromisoformat(os.environ.get("VPS_TRAFFIC_AS_OF_DATE", dt.date.today().isoformat()))
        current = anchor(today.year, today.month, args.reset_day)
        if today < current:
            year, month = previous_month(today.year, today.month)
            start = anchor(year, month, args.reset_day)
            end = current
        else:
            start = current
            year, month = next_month(today.year, today.month)
            end = anchor(year, month, args.reset_day)
        daily = item["traffic"]["day"]
        rows = []
        for row in daily:
            day = record_date(row["date"])
            rx, tx = row["rx"], row["tx"]
            if not isinstance(rx, int) or not isinstance(tx, int) or rx < 0 or tx < 0:
                raise ValueError("vnStat 日记录含无效字节数")
            if start <= day <= today:
                rows.append((day, rx, tx))
        if not rows:
            raise ValueError("本账期尚无 vnStat 日记录")
        rx = sum(row[1] for row in rows)
        tx = sum(row[2] for row in rows)
        quota = args.quota_gb * 1000**3 if args.quota_gb is not None else args.quota_gib * 1024**3
        if quota <= 0:
            raise ValueError("额度必须大于零")
        used = rx + tx
        percent = used * 100 / quota
        created = record_date(item["created"]["date"])
        partial = created > start or min(row[0] for row in rows) > start
        print(f"网卡: {args.interface}")
        print(f"账期: {start.isoformat()} 至 {end.isoformat()}（结束日不含）")
        amount = args.quota_gb if args.quota_gb is not None else args.quota_gib
        unit = "GB" if args.quota_gb is not None else "GiB"
        divisor = 1000**3 if args.quota_gb is not None else 1024**3
        print(f"下载: {rx / divisor:.2f} {unit}；上传: {tx / divisor:.2f} {unit}")
        print(f"合计: {used / divisor:.2f} / {amount} {unit}（{percent:.1f}%）")
        if partial:
            print("数据状态: 不完整；vnStat 建库或本账期首条记录晚于账期开始")
        else:
            print("数据状态: 已覆盖账期起点；仍可能与服务商计费口径不同")
        if percent >= args.critical_percent:
            print("额度状态: 严重阈值已达到")
        elif percent >= args.warn_percent:
            print("额度状态: 预警阈值已达到")
        else:
            print("额度状态: 未达到阈值")
        return 0
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        print(f"无法计算可信的流量额度: {exc}", file=sys.stderr)
        return 30


if __name__ == "__main__":
    sys.exit(main())
