#!/usr/bin/env python3
"""make_demo_udisk.py — 生成录制/演示用的 U 盘素材目录。

用法：
    python tools/make_demo_udisk.py                # 输出到 dist/demo_udisk
    python tools/make_demo_udisk.py --out D:/udisk

产物（文件名刻意包含中文，用于验证 GBK 位图字库）：
    01_红绿灯_112454.mp4     0–30 s
    02_变道_112507.mp4       0–30 s
    03_斑马线_113539.mp4     60–90 s
    04_道路_113343.mp4       0–30 s
    测试图片_道路.jpg         从 113539 的 65 s 抽一帧（静态图片输入测试）
    README.txt

依赖：ffmpeg（默认 `D:/Program Files/FormatFactory/ffmpeg.exe`，可用 --ffmpeg 指定）。
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "video_review", "src")

CLIPS = [
    ("112454", 0, 30, "01_红绿灯_112454.mp4"),
    ("112507", 0, 30, "02_变道_112507.mp4"),
    ("113539", 60, 90, "03_斑马线_113539.mp4"),
    ("113343", 0, 30, "04_道路_113343.mp4"),
]
STILL = ("113539", 65, "测试图片_道路.jpg")

README = """演示 U 盘素材
================
01_红绿灯_112454.mp4   十字路口红绿灯（约 30 s）
02_变道_112507.mp4     车道线/变道（约 30 s）
03_斑马线_113539.mp4   斑马线 + 前车遮挡（约 30 s）
04_道路_113343.mp4     常规道路（约 30 s）
限速标志_测试帧.jpg     静态图片输入测试

用法：
1. 把本目录整体拷到 U 盘（exFAT/FAT32 均可）；
2. 板端选择「U盘视频流」→ 进入本目录 → 按顺序选 3–4 个文件 → START；
3. 图片可与视频混选，占用对应宫格。
"""


def run(cmd: list[str]) -> int:
    print("+", " ".join(cmd))
    return subprocess.call(cmd)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "dist", "demo_udisk"))
    ap.add_argument("--ffmpeg", default=r"D:/Program Files/FormatFactory/ffmpeg.exe")
    args = ap.parse_args()

    if not os.path.isfile(args.ffmpeg):
        print(f"ffmpeg not found: {args.ffmpeg}", file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)

    for vid, start, end, name in CLIPS:
        src = os.path.join(SRC, f"video_20260929_{vid}.mp4")
        if not os.path.isfile(src):
            print(f"missing source: {src}", file=sys.stderr)
            continue
        dst = os.path.join(args.out, name)
        rc = run([args.ffmpeg, "-y", "-ss", str(start), "-to", str(end), "-i", src,
                  "-c", "copy", "-avoid_negative_ts", "make_zero", dst])
        print(f"  -> {dst} rc={rc}")

    vid, ts, name = STILL
    src = os.path.join(SRC, f"video_20260929_{vid}.mp4")
    if os.path.isfile(src):
        dst = os.path.join(args.out, name)
        rc = run([args.ffmpeg, "-y", "-ss", str(ts), "-i", src, "-frames:v", "1", "-q:v", "2", dst])
        print(f"  -> {dst} rc={rc}")

    with open(os.path.join(args.out, "README.txt"), "w", encoding="utf-8") as f:
        f.write(README)

    total = sum(os.path.getsize(os.path.join(args.out, n)) for n in os.listdir(args.out))
    print(f"done: {args.out}  files={len(os.listdir(args.out))}  size={total/1048576:.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
