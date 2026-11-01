#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/night_eval/luma_stats.py
Evaluate frame luminance statistics across daytime test videos and simulate AUTO night mode hysteresis.
"""

import argparse
import csv
import glob
import os
import sys
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
DEFAULT_SRC = os.path.join(REPO_ROOT, "video_review", "src")
DEFAULT_OUT = os.path.join(SCRIPT_DIR, "out")

TARGET_VIDEOS = [
    "video_20260929_112454.mp4",
    "video_20260929_112507.mp4",
    "video_20260929_112739.mp4",
    "video_20260929_113343.mp4",
    "video_20260929_113421.mp4",
    "video_20260929_113452.mp4",
    "video_20260929_113539.mp4",
]


def process_single_video(video_path, out_dir):
    stem = os.path.splitext(os.path.basename(video_path))[0]
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0

    frame_records = []
    lumas = []
    frame_idx = 0

    # AUTO hysteresis state machine
    is_night = False
    dark_cnt = 0
    bright_cnt = 0
    night_enters = 0

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        # Resize to 960x540 using INTER_AREA
        res = cv2.resize(frame, (960, 540), interpolation=cv2.INTER_AREA)

        # Formula: Y = (R + 2*G + B) / 4 (integer 8-bit)
        b = res[:, :, 0].astype(np.uint16)
        g = res[:, :, 1].astype(np.uint16)
        r = res[:, :, 2].astype(np.uint16)
        y_pix = (r + (g << 1) + b) >> 2
        luma = int(round(float(y_pix.mean())))

        time_sec = frame_idx / fps

        # 8-frame hysteresis: < 48 enters night, > 64 exits night
        if not is_night:
            if luma < 48:
                dark_cnt += 1
                if dark_cnt >= 8:
                    is_night = True
                    night_enters += 1
                    dark_cnt = 0
                    bright_cnt = 0
            else:
                dark_cnt = 0
        else:
            if luma > 64:
                bright_cnt += 1
                if bright_cnt >= 8:
                    is_night = False
                    bright_cnt = 0
                    dark_cnt = 0
            else:
                bright_cnt = 0

        frame_records.append((frame_idx, round(time_sec, 3), luma, int(is_night)))
        lumas.append(luma)
        frame_idx += 1

    cap.release()

    if not lumas:
        raise RuntimeError(f"No frames read from {video_path}")

    # Write per-video frame CSV
    per_video_csv = os.path.join(out_dir, f"{stem}.csv")
    with open(per_video_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["frame", "time_sec", "luma", "is_night"])
        writer.writerows(frame_records)

    larr = np.array(lumas, dtype=np.int32)
    min_idx = int(np.argmin(larr))
    min_sec = round(min_idx / fps, 2)

    return {
        "video": os.path.basename(video_path),
        "frames": len(larr),
        "min": int(np.min(larr)),
        "p5": round(float(np.percentile(larr, 5)), 1),
        "median": round(float(np.median(larr)), 1),
        "max": int(np.max(larr)),
        "min_frame": min_idx,
        "min_sec": min_sec,
        "night_enters": night_enters,
    }


def main():
    parser = argparse.ArgumentParser(description="Evaluate video luminance statistics and simulate AUTO night mode.")
    parser.add_argument("--src", default=DEFAULT_SRC, help="Source directory containing test videos")
    parser.add_argument("--out", default=DEFAULT_OUT, help="Output directory for CSV files")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)

    # Locate target videos
    video_paths = []
    for fname in TARGET_VIDEOS:
        path = os.path.join(args.src, fname)
        if not os.path.isfile(path):
            # Fallback search by pattern
            matches = sorted(glob.glob(os.path.join(args.src, fname)))
            if matches:
                path = matches[0]
            else:
                sys.stderr.write(f"Error: Target video not found: {path}\n")
                sys.exit(1)
        video_paths.append(path)

    # Process videos in parallel threads (I/O & OpenCV decode release GIL)
    with ThreadPoolExecutor(max_workers=min(len(video_paths), 8)) as executor:
        futures = [executor.submit(process_single_video, vpath, args.out) for vpath in video_paths]
        results = [f.result() for f in futures]

    # Save summary CSV: luma_stats.csv
    summary_csv = os.path.join(args.out, "luma_stats.csv")
    fieldnames = ["video", "frames", "min", "p5", "median", "max", "min_frame", "min_sec", "night_enters"]
    with open(summary_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)

    # Print summary table
    print("=" * 96)
    print(f"{'Video':<30} {'Frames':>7} {'Min':>5} {'P5':>6} {'Median':>7} {'Max':>5} {'Min Frame (s)':>16} {'Night Enters':>14}")
    print("-" * 96)
    for r in results:
        min_str = f"{r['min_frame']} ({r['min_sec']:.2f}s)"
        print(f"{r['video']:<30} {r['frames']:>7} {r['min']:>5} {r['p5']:>6.1f} {r['median']:>7.1f} {r['max']:>5} {min_str:>16} {r['night_enters']:>14}")
    print("=" * 96)

    # Check gate criteria: all min > 64 and night_enters == 0
    all_min_pass = all(r["min"] > 64 for r in results)
    all_enters_zero = all(r["night_enters"] == 0 for r in results)

    if all_min_pass and all_enters_zero:
        print("GATE PASS: All videos have min luminance > 64 and 0 night mode activations.")
    else:
        print("GATE FAIL: Threshold violation or night mode activated on daytime videos.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
