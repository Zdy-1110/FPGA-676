# -*- coding: utf-8 -*-
"""FPGA 斑马线测试向量生成脚本。

生成 5 段测试向量供 RTL 逐行/逐帧对拍：
- seg_112454_pos: 0–3.55 s
- seg_113539_pos: 63.5–69.5 s
- seg_112507_neg: 8–16 s
- seg_113343_neg: 8–16 s
- seg_113421_weak: 0–13 s

每段包含：
- frames.bin: 960x540 RGB565 小端 uint16
- frames.csv: 每帧 idx,t,zebra,n_rows,y_min,y_max
- rows.csv: 每行 idx,row,y,white_px,runs,runs_valid,mean_w,max_w,min_w,cand (行数 = 帧数 * 180)
"""

import csv
import os
import sys
import cv2
import numpy as np

# 保证根目录在 sys.path
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from tools.zebra_fpga.model import load_params, frame_stats, ZebraFilter

VECTORS_ROOT = os.path.join(REPO_ROOT, "log", "zebra_fpga", "vectors")

SEGMENTS = [
    {
        "name": "seg_112454_pos",
        "video": os.path.join(REPO_ROOT, "video_review", "src", "video_20260929_112454.mp4"),
        "t_start": 0.0,
        "t_end": 3.55,
    },
    {
        "name": "seg_113539_pos",
        "video": os.path.join(REPO_ROOT, "video_review", "src", "video_20260929_113539.mp4"),
        "t_start": 63.5,
        "t_end": 69.5,
    },
    {
        "name": "seg_112507_neg",
        "video": os.path.join(REPO_ROOT, "video_review", "src", "video_20260929_112507.mp4"),
        "t_start": 8.0,
        "t_end": 16.0,
    },
    {
        "name": "seg_113343_neg",
        "video": os.path.join(REPO_ROOT, "video_review", "src", "video_20260929_113343.mp4"),
        "t_start": 8.0,
        "t_end": 16.0,
    },
    {
        "name": "seg_113421_weak",
        "video": os.path.join(REPO_ROOT, "video_review", "src", "video_20260929_113421.mp4"),
        "t_start": 0.0,
        "t_end": 13.0,
    },
]


def bgr_to_rgb565(bgr_960: np.ndarray) -> np.ndarray:
    """将 (540, 960, 3) BGR 图像量化为 (540, 960) uint16 RGB565。"""
    b = bgr_960[:, :, 0]
    g = bgr_960[:, :, 1]
    r = bgr_960[:, :, 2]
    r5 = (r >> 3).astype(np.uint16)
    g6 = (g >> 2).astype(np.uint16)
    b5 = (b >> 3).astype(np.uint16)
    return (r5 << 11) | (g6 << 5) | b5


def export_segment(seg_info: dict, params: dict):
    seg_name = seg_info["name"]
    video_path = seg_info["video"]
    t_start = seg_info["t_start"]
    t_end = seg_info["t_end"]

    out_dir = os.path.join(VECTORS_ROOT, seg_name)
    os.makedirs(out_dir, exist_ok=True)

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    w_target, h_target = params.get("w", 960), params.get("h", 540)

    start_frame = int(round(t_start * fps))
    end_frame = int(round(t_end * fps))

    z_filter = ZebraFilter(params.get("hyst_pos", 3), params.get("hyst_neg", 6))

    bin_frames = []
    frames_records = []
    rows_records = []

    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
    cur_f = start_frame
    idx = 0

    while cur_f <= end_frame:
        ret, frame_bgr = cap.read()
        if not ret:
            break

        # 10 fps 抽帧: step = 3
        if (cur_f - start_frame) % 3 == 0:
            t_cur = cur_f / fps
            frame_resized = cv2.resize(frame_bgr, (w_target, h_target), interpolation=cv2.INTER_AREA)
            rgb565 = bgr_to_rgb565(frame_resized)
            bin_frames.append(rgb565)

            # 运行模型
            f_stat = frame_stats(rgb565, params)
            zebra_out = z_filter.update(f_stat["zebra_raw"])

            # 记录 frames.csv
            frames_records.append({
                "idx": idx,
                "t": f"{t_cur:.3f}",
                "zebra": zebra_out,
                "n_rows": f_stat["n_rows"],
                "y_min": f_stat["y_min"],
                "y_max": f_stat["y_max"],
            })

            # 记录 rows.csv
            for r in f_stat["rows"]:
                rows_records.append({
                    "idx": idx,
                    "row": r["row"],
                    "y": r["y"],
                    "white_px": r["white_px"],
                    "runs": r["runs_cnt"],
                    "runs_valid": r["runs_valid"],
                    "mean_w": r["mean_w"],
                    "max_w": r["max_w"],
                    "min_w": r["min_w"],
                    "cand": r["cand"],
                })

            idx += 1

        cur_f += 1

    cap.release()

    # 1. 写入 frames.bin
    bin_path = os.path.join(out_dir, "frames.bin")
    with open(bin_path, "wb") as f:
        for f_mat in bin_frames:
            f.write(f_mat.astype("<u2").tobytes())

    # 2. 写入 frames.csv
    frames_csv_path = os.path.join(out_dir, "frames.csv")
    with open(frames_csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["idx", "t", "zebra", "n_rows", "y_min", "y_max"])
        writer.writeheader()
        writer.writerows(frames_records)

    # 3. 写入 rows.csv
    rows_csv_path = os.path.join(out_dir, "rows.csv")
    with open(rows_csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["idx", "row", "y", "white_px", "runs", "runs_valid", "mean_w", "max_w", "min_w", "cand"])
        writer.writeheader()
        writer.writerows(rows_records)

    n_frames = len(frames_records)
    n_rows = len(rows_records)
    print(f"[{seg_name}] Exported: {n_frames} frames, {n_rows} rows (expected {n_frames * 180}) -> {out_dir}")
    assert n_rows == n_frames * 180, f"Rows count mismatch: {n_rows} != {n_frames * 180}"


def main():
    params = load_params()
    print("=== Generating FPGA Zebra Test Vectors ===")
    for seg in SEGMENTS:
        export_segment(seg, params)
    print("=== All Test Vectors Generated Successfully ===")


if __name__ == "__main__":
    main()
