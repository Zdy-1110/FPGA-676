#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_navfile.py - 生成模拟导航路线文件 (.nav)

从真值时间线 CSV 中提取 nav_maneuver 行，生成时间驱动的导航指令区间文件。
"""

import os
import sys
import csv
import argparse

MANEUVER_MAP = {
    'right': 'R',
    'left': 'L',
    'uturn': 'U',
    'u-turn': 'U',
    'straight': 'S',
}

def parse_args():
    parser = argparse.ArgumentParser(description="生成模拟导航路线文件 (.nav)")
    parser.add_argument(
        "-i", "--timeline",
        default="video_review/gt/112739_timeline.csv",
        help="输入时间线 CSV 文件路径 (默认: video_review/gt/112739_timeline.csv)"
    )
    parser.add_argument(
        "-o", "--out",
        default="tools/nav_proto/out/video_20260929_112739.nav",
        help="输出 .nav 文件路径 (默认: tools/nav_proto/out/video_20260929_112739.nav)"
    )
    return parser.parse_args()

def main():
    args = parse_args()

    if not os.path.exists(args.timeline):
        sys.stderr.write(f"Error: timeline file not found: {args.timeline}\n")
        sys.exit(1)

    entries = []
    with open(args.timeline, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("field") == "nav_maneuver":
                t_str = row.get("t_start", "").strip()
                val = row.get("value", "").strip().lower()
                try:
                    t_val = float(t_str)
                except ValueError:
                    sys.stderr.write(f"Error: invalid t_start '{t_str}'\n")
                    sys.exit(1)
                entries.append((t_val, val))

    entries.sort(key=lambda x: x[0])

    lines = ["# 模拟导航模块输出，由 GT 时间线生成\n"]
    n = len(entries)
    for i, (t0, val) in enumerate(entries):
        if val not in MANEUVER_MAP:
            sys.stderr.write(f"Error: unknown nav_maneuver value '{val}' at t={t0}\n")
            sys.exit(1)
        dir_char = MANEUVER_MAP[val]
        if i + 1 < n:
            next_t = entries[i + 1][0]
            t1 = min(next_t, t0 + 6.0)
        else:
            t1 = t0 + 6.0
        lines.append(f"{t0:.1f} {t1:.1f} {dir_char}\n")

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.out, "w", encoding="utf-8") as f:
        f.writelines(lines)

    valid_count = len(lines) - 1
    print(f"Generated {valid_count} nav instructions to {args.out}")

if __name__ == "__main__":
    main()
