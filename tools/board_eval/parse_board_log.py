# -*- coding: utf-8 -*-
"""板端评测日志解析器：将板端 ADAS_EVAL 日志转为 eval_ref.py 可读的 states.csv。

板端日志格式：
  eval t=<ch0播放秒,%.2f> sig=<L>/<S>/<R> ll=<valid>,<solid> rl=<valid>,<solid> lane=<0|1|2> mov=<0|1> dec=0x<3位hex>

映射口径：
  - sig: 0->none, 1->red, 2->yellow, 3->green (依据 tools/adas/tl_det.h: TL_COLOR_*)
  - ll/rl: valid=0->none; valid=1 & solid=1->white_solid; valid=1 & solid=0->white_dashed
  - mov: 1->moving, 0->stopped
  - 循环检测: t 回卷 (t < prev_t) 视为视频循环播放，仅截取第一遍

输出目录结构：
  <out_dir>/<vid>/states.csv
"""

import argparse
import csv
import glob
import os
import re
import sys

SIG_MAP = {
    0: "none",
    1: "red",
    2: "yellow",
    3: "green",
}

EVAL_PATTERN = re.compile(
    r"eval\s+"
    r"t=(?P<t>[-+]?[0-9]*\.?[0-9]+)\s+"
    r"sig=(?P<sig_l>[0-9]+)/(?P<sig_s>[0-9]+)/(?P<sig_r>[0-9]+)\s+"
    r"ll=(?P<ll_v>[0-9]+),(?P<ll_s>[0-9]+)\s+"
    r"rl=(?P<rl_v>[0-9]+),(?P<rl_s>[0-9]+)\s+"
    r"lane=(?P<lane>[0-9]+)\s+"
    r"mov=(?P<mov>[0-9]+)\s+"
    r"dec=0x(?P<dec>[0-9a-fA-F]+)"
)

CSV_COLUMNS = [
    "frame", "t", "sig_left", "sig_straight", "sig_right",
    "raw_left", "raw_straight", "raw_right", "n_lights", "lights",
    "left_line", "right_line", "left_cov", "right_cov",
    "ego_motion", "motion_score", "lane", "dec"
]


def map_sig(code_int: int) -> str:
    return SIG_MAP.get(code_int, "none")


def map_line(valid: int, solid: int) -> str:
    if valid == 0:
        return "none"
    return "white_solid" if solid == 1 else "white_dashed"


def map_motion(mov: int) -> str:
    return "moving" if mov == 1 else "stopped"


def extract_vid(file_path: str) -> str:
    base = os.path.basename(file_path)
    m = re.search(r"(\d{6})", base)
    if m:
        return m.group(1)
    name, _ = os.path.splitext(base)
    return name


def parse_log_file(file_path: str, time_offset: float = 0.0, drop_neg_t: bool = False):
    rows = []
    prev_t = None
    loop_stopped = False
    total_eval_lines = 0

    with open(file_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = EVAL_PATTERN.search(line)
            if not m:
                continue

            total_eval_lines += 1
            t_val = float(m.group("t"))

            # 循环回卷检测：单遍播放，t 从 0 递增；若 t 回卷（变小）只取第一遍
            if prev_t is not None and t_val < prev_t:
                loop_stopped = True
                break

            prev_t = t_val
            t_out = round(t_val - time_offset, 3)
            if drop_neg_t and t_out < 0:
                continue

            sig_l = map_sig(int(m.group("sig_l")))
            sig_s = map_sig(int(m.group("sig_s")))
            sig_r = map_sig(int(m.group("sig_r")))

            ll_v = int(m.group("ll_v"))
            ll_s = int(m.group("ll_s"))
            rl_v = int(m.group("rl_v"))
            rl_s = int(m.group("rl_s"))

            left_line = map_line(ll_v, ll_s)
            right_line = map_line(rl_v, rl_s)

            mov = int(m.group("mov"))
            ego_motion = map_motion(mov)

            lane = int(m.group("lane"))
            dec_hex = m.group("dec").lower()

            non_none_lights = sum(1 for s in (sig_l, sig_s, sig_r) if s not in ("none", "off"))

            row = {
                "frame": len(rows),
                "t": f"{t_out:.3f}",
                "sig_left": sig_l,
                "sig_straight": sig_s,
                "sig_right": sig_r,
                "raw_left": sig_l,
                "raw_straight": sig_s,
                "raw_right": sig_r,
                "n_lights": non_none_lights,
                "lights": "",
                "left_line": left_line,
                "right_line": right_line,
                "left_cov": "1.0" if ll_v else "0.0",
                "right_cov": "1.0" if rl_v else "0.0",
                "ego_motion": ego_motion,
                "motion_score": "",
                "lane": lane,
                "dec": f"0x{dec_hex}",
            }
            rows.append(row)

    return rows, loop_stopped, total_eval_lines


def process_logs(log_paths, out_dir, time_offset=0.0, drop_neg_t=False):
    os.makedirs(out_dir, exist_ok=True)
    summary = []

    for path in log_paths:
        if not os.path.isfile(path):
            print(f"[WARN] 文件不存在: {path}", file=sys.stderr)
            continue

        vid = extract_vid(path)
        rows, loop_stopped, _total = parse_log_file(path, time_offset, drop_neg_t)

        vid_out_dir = os.path.join(out_dir, vid)
        os.makedirs(vid_out_dir, exist_ok=True)
        out_csv = os.path.join(vid_out_dir, "states.csv")

        with open(out_csv, "w", encoding="utf-8-sig", newline="") as f:
            w = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
            w.writeheader()
            for r in rows:
                w.writerow(r)

        t_range = f"[{rows[0]['t']}s ~ {rows[-1]['t']}s]" if rows else "[无数据]"
        loop_flag = " (截断回卷)" if loop_stopped else ""
        print(f"解析 {os.path.basename(path)} -> {out_csv}: {len(rows)} 帧 {t_range}{loop_flag}")
        summary.append((vid, len(rows), out_csv))

    return summary


def main():
    parser = argparse.ArgumentParser(description="板端日志转 states.csv 工具")
    parser.add_argument(
        "logs",
        nargs="*",
        help="板端日志文件路径（支持通配符或多个文件），如 112454.log",
    )
    parser.add_argument(
        "--logs-list",
        nargs="+",
        dest="opt_logs",
        help="板端日志文件路径列表",
    )
    parser.add_argument(
        "--out-dir",
        default="tools/board_eval/out",
        help="输出 states.csv 根目录（默认: tools/board_eval/out）",
    )
    parser.add_argument(
        "--time-offset",
        type=float,
        default=0.0,
        help="时间偏移补偿 (t_out = t - time_offset，默认: 0.0)",
    )
    parser.add_argument(
        "--drop-negative-t",
        action="store_true",
        help="丢弃 offset 补偿后小于 0 的帧",
    )

    args = parser.parse_args()

    input_paths = []
    candidates = (args.logs or []) + (args.opt_logs or [])
    for pat in candidates:
        matched = glob.glob(pat)
        if matched:
            input_paths.extend(matched)
        else:
            input_paths.append(pat)

    if not input_paths:
        parser.print_help()
        print("\n错误: 未指定任何板端日志文件。", file=sys.stderr)
        return 1

    input_paths = sorted(set(input_paths))
    res = process_logs(input_paths, args.out_dir, args.time_offset, args.drop_negative_t)
    print(f"\n全部完成: 共处理 {len(res)} 个日志，输出至 {args.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
