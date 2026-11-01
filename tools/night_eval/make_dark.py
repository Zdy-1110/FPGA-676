#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/night_eval/make_dark.py
Extract day frames, generate darkened simulated night frames (Y~25, Y~40),
and simulate FPGA gamma=0.5 enhancement on 960x540.
"""

import argparse
import csv
import os
import shutil
import sys

import cv2
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
DEFAULT_SRC = os.path.join(REPO_ROOT, "video_review", "src")
DEFAULT_OUT_DARK = os.path.join(SCRIPT_DIR, "out", "dark")
DEFAULT_OUT_ROOT = os.path.join(SCRIPT_DIR, "out")

SOURCES = [
    ("112739", "video_20260929_112739.mp4"),
    ("113539", "video_20260929_113539.mp4"),
]
POSITIONS = [("10", 0.10), ("50", 0.50), ("90", 0.90)]

# Gamma=0.5 LUT: out = round(255 * (in / 255)^0.5)
GAMMA_LUT = np.array([int(round(255.0 * ((i / 255.0) ** 0.5))) for i in range(256)], dtype=np.uint8)


def calc_luma_960x540(img_bgr):
    """Calculate integer mean luma Y = (R + 2G + B) / 4 on 960x540 resized image."""
    if (img_bgr.shape[1], img_bgr.shape[0]) != (960, 540):
        img_bgr = cv2.resize(img_bgr, (960, 540), interpolation=cv2.INTER_AREA)
    b = img_bgr[:, :, 0].astype(np.uint16)
    g = img_bgr[:, :, 1].astype(np.uint16)
    r = img_bgr[:, :, 2].astype(np.uint16)
    y_pix = (r + (g << 1) + b) >> 2
    return float(y_pix.mean())


def extract_frame_at_ratio(video_path, ratio):
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video {video_path}")
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    target_idx = int(round(total_frames * ratio))
    target_idx = min(max(0, target_idx), total_frames - 1)
    cap.set(cv2.CAP_PROP_POS_FRAMES, target_idx)
    ret, frame = cap.read()
    cap.release()
    if not ret or frame is None:
        raise RuntimeError(f"Failed to read frame {target_idx} from {video_path}")
    return target_idx, frame


def make_dark_image(orig_bgr, target_y, seed=42):
    """
    Linear darkening to mean target_y, plus Gaussian noise sigma=3, clipped to 0..255.
    """
    b = orig_bgr[:, :, 0].astype(np.float64)
    g = orig_bgr[:, :, 1].astype(np.float64)
    r = orig_bgr[:, :, 2].astype(np.float64)
    orig_y = ((r + 2.0 * g + b) / 4.0).mean()
    scale = target_y / orig_y

    scaled = orig_bgr.astype(np.float32) * scale
    rng = np.random.RandomState(seed)
    noise = rng.normal(0.0, 3.0, size=orig_bgr.shape).astype(np.float32)
    dark = np.clip(np.round(scaled + noise), 0, 255).astype(np.uint8)
    return dark


def main():
    parser = argparse.ArgumentParser(description="Generate dark test dataset and simulate gamma enhancement.")
    parser.add_argument("--src", default=DEFAULT_SRC, help="Source directory containing test videos")
    parser.add_argument("--out-dark", default=DEFAULT_OUT_DARK, help="Output directory for dark images and csv")
    parser.add_argument("--out-root", default=DEFAULT_OUT_ROOT, help="Output root directory")
    args = parser.parse_args()

    os.makedirs(args.out_dark, exist_ok=True)
    os.makedirs(args.out_root, exist_ok=True)

    dark_records = []

    for vid_tag, vid_name in SOURCES:
        vid_path = os.path.join(args.src, vid_name)
        if not os.path.isfile(vid_path):
            sys.stderr.write(f"Error: video not found at {vid_path}\n")
            sys.exit(1)

        for pos_tag, ratio in POSITIONS:
            frame_idx, frame = extract_frame_at_ratio(vid_path, ratio)

            # 1. Day image (original 1920x1080, quality 92)
            day_name = f"day_{vid_tag}_{pos_tag}.jpg"
            day_path = os.path.join(args.out_dark, day_name)
            cv2.imwrite(day_path, frame, [cv2.IMWRITE_JPEG_QUALITY, 92])

            # 2. Night25 and Night40 versions
            targets = [("night25", 25.0, 100), ("night40", 40.0, 200)]
            for prefix, target_luma, seed_base in targets:
                seed = seed_base + int(vid_tag) % 1000 + int(pos_tag)
                dark_img = make_dark_image(frame, target_luma, seed=seed)

                # Save original-size dark image (quality 92)
                dark_name = f"{prefix}_{vid_tag}_{pos_tag}.jpg"
                dark_path = os.path.join(args.out_dark, dark_name)
                cv2.imwrite(dark_path, dark_img, [cv2.IMWRITE_JPEG_QUALITY, 92])

                # Reload dark image to measure exact on-disk JPEG luminance
                dark_on_disk = cv2.imread(dark_path)
                y_mean = calc_luma_960x540(dark_on_disk)

                # 3. Simulate FPGA gamma enhancement on 960x540
                dark_small = cv2.resize(dark_on_disk, (960, 540), interpolation=cv2.INTER_AREA)
                gamma_small = cv2.LUT(dark_small, GAMMA_LUT)

                gamma_name = f"sim_gamma_{dark_name}"
                gamma_path = os.path.join(args.out_dark, gamma_name)
                cv2.imwrite(gamma_path, gamma_small, [cv2.IMWRITE_JPEG_QUALITY, 92])

                # Measure enhanced luma on disk
                gamma_on_disk = cv2.imread(gamma_path)
                enhanced_y_mean = calc_luma_960x540(gamma_on_disk)

                dark_records.append({
                    "filename": dark_name,
                    "y_mean": round(y_mean, 2),
                    "enhanced_y_mean": round(enhanced_y_mean, 2),
                })

    # Write out/dark/dark_set.csv and out/dark_set.csv
    csv_paths = [
        os.path.join(args.out_dark, "dark_set.csv"),
        os.path.join(args.out_root, "dark_set.csv"),
    ]
    for p in csv_paths:
        with open(p, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=["filename", "y_mean", "enhanced_y_mean"])
            writer.writeheader()
            writer.writerows(dark_records)

    print(f"Generated {len(dark_records)} dark images + corresponding sim_gamma images in {args.out_dark}")
    print("=" * 64)
    print(f"{'Filename':<30} {'Y Mean':>12} {'Enhanced Y Mean':>18}")
    print("-" * 64)
    for r in dark_records:
        print(f"{r['filename']:<30} {r['y_mean']:>12.2f} {r['enhanced_y_mean']:>18.2f}")
    print("=" * 64)

    # Verify acceptance criteria
    all_n25_pass = all(20.0 <= r["y_mean"] <= 30.0 for r in dark_records if r["filename"].startswith("night25"))
    all_n40_pass = all(35.0 <= r["y_mean"] <= 45.0 for r in dark_records if r["filename"].startswith("night40"))

    if all_n25_pass and all_n40_pass:
        print("Acceptance check PASSED: night25 Y mean in [20, 30], night40 Y mean in [35, 45].")
    else:
        print("Acceptance check FAILED: Y mean out of range.")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
