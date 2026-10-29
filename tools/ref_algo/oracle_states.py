# -*- coding: utf-8 -*-
"""从真值时间轴生成"理想感知"的 states.csv（仅标准库）。

用途：为离线评测提供理想感知输入，验证判决函数与评测脚本本身是否正确。

用法：
  python oracle_states.py --gt-dir <gt目录> --out <输出根目录> [--dt 0.1]

对 gt 目录下每个 <id>_timeline.csv（跳过 111440_* 与下划线开头的文件）：
  - 时长 = 该视频所有行 t_end 的最大值；
  - 从 t=0 到时长按 dt 生成帧（frame = round(t*30)）；
  - sig_*：取真值，无真值或 unknown 写 none；raw_* 与 sig_* 相同；
  - left_line/right_line：取 ego_left_line/ego_right_line，无真值/unknown/curb 写 none；
  - ego_motion：moving/braking/starting -> moving，stopped -> stopped，无真值写 moving；
  - n_lights=0，lights 留空，cov 与 score 写 0。
输出到 <out>/<id>/states.csv，列名与感知 states.csv 完全一致。
"""

import argparse
import csv
import glob
import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


COLUMNS = [
    "frame", "t", "sig_left", "sig_straight", "sig_right",
    "raw_left", "raw_straight", "raw_right", "n_lights", "lights",
    "left_line", "right_line", "left_cov", "right_cov",
    "ego_motion", "motion_score",
]

SIG_FIELDS = ["sig_left", "sig_straight", "sig_right"]
LANE_FIELDS = [("left_line", "ego_left_line"), ("right_line", "ego_right_line")]


def read_timeline(path):
    rows = []
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            try:
                t0 = float(r["t_start"])
                t1 = float(r["t_end"])
            except (KeyError, TypeError, ValueError):
                continue
            rows.append({
                "video": (r.get("video") or "").strip(),
                "t_start": t0,
                "t_end": t1,
                "field": (r.get("field") or "").strip(),
                "value": (r.get("value") or "").strip().lower(),
            })
    return rows


def query(rows, field, t):
    """返回该 field 中覆盖 t 的、t_start 最大的一行的 value，没有则 None。"""
    best = None
    for r in rows:
        if r["field"] != field:
            continue
        if r["t_start"] <= t <= r["t_end"]:
            if best is None or r["t_start"] > best["t_start"]:
                best = r
            elif r["t_start"] == best["t_start"]:
                best = r
    return best["value"] if best else None


def sig_value(rows, field, t):
    v = query(rows, field, t)
    if v is None or v == "unknown":
        return "none"
    return v


def line_value(rows, field, t):
    v = query(rows, field, t)
    if v is None or v in ("unknown", "curb"):
        return "none"
    return v


def motion_value(rows, t):
    v = query(rows, "ego_motion", t)
    if v is None:
        return "moving"
    if v in ("moving", "braking", "starting"):
        return "moving"
    if v == "stopped":
        return "stopped"
    return "moving"


def main():
    ap = argparse.ArgumentParser(description="从真值时间轴生成理想 states.csv")
    ap.add_argument("--gt-dir", default=r"E:\Project\nesai2026\video_review\gt")
    ap.add_argument("--out", required=True)
    ap.add_argument("--dt", type=float, default=0.1)
    args = ap.parse_args()

    pattern = os.path.join(args.gt_dir, "*_timeline.csv")
    files = sorted(glob.glob(pattern))
    made = []
    for path in files:
        base = os.path.basename(path)
        if base.startswith("_"):
            continue
        if base.startswith("111440"):
            continue
        rows = read_timeline(path)
        if not rows:
            continue
        video = rows[0]["video"]
        if not video:
            video = base.replace("_timeline.csv", "")
        duration = max(r["t_end"] for r in rows)

        out_dir = os.path.join(args.out, video)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, "states.csv")

        n = int(duration / args.dt + 1e-9)
        with open(out_path, "w", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(COLUMNS)
            for i in range(n + 1):
                t = round(i * args.dt, 6)
                if t > duration + 1e-9:
                    break
                sigs = {fl: sig_value(rows, fl, t) for fl in SIG_FIELDS}
                lane = {out: line_value(rows, src, t) for out, src in LANE_FIELDS}
                motion = motion_value(rows, t)
                w.writerow([
                    int(round(t * 30)), t,
                    sigs["sig_left"], sigs["sig_straight"], sigs["sig_right"],
                    sigs["sig_left"], sigs["sig_straight"], sigs["sig_right"],
                    0, "",
                    lane["left_line"], lane["right_line"],
                    0, 0, motion, 0,
                ])
        made.append((video, n + 1, out_path))
        print("生成 %s 帧: %s" % (n + 1, out_path))
    print("共生成 %d 个视频的 states.csv" % len(made))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
