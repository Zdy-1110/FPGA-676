# -*- coding: utf-8 -*-
"""将 seg_board 的 csv 转换为 RTL testbench 适用的 frames_ref.hex 与 rows_ref.hex。

输出路径：
- D:/pango_build/4_15_PCIE_DMA/sim/lane/seg_board/frames_ref.hex
- D:/pango_build/4_15_PCIE_DMA/sim/lane/seg_board/rows_ref.hex
"""

import csv
import os
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
type_map = {"none": 0, "dashed": 1, "solid": 2, "double_yellow": 3}

seg = "seg_board"
seg_dir = os.path.join(REPO_ROOT, "log", "lane_fpga", "vectors", seg)
out_dir = f"D:/pango_build/4_15_PCIE_DMA/sim/lane/{seg}"
os.makedirs(out_dir, exist_ok=True)

frames_csv_path = os.path.join(seg_dir, "frames.csv")
rows_csv_path = os.path.join(seg_dir, "rows.csv")

frames_hex_path = os.path.join(out_dir, "frames_ref.hex")
rows_hex_path = os.path.join(out_dir, "rows_ref.hex")

# 1. 转换 frames.csv -> frames_ref.hex
with open(frames_csv_path, "r", encoding="utf-8") as f:
    frames_reader = list(csv.DictReader(f))

with open(frames_hex_path, "w", encoding="utf-8") as out_f:
    for r in frames_reader:
        fields = [
            int(r["left_n"]),
            int(r["left_sum_y"]),
            int(r["left_sum_yy"]),
            int(r["left_sum_x"]),
            int(r["left_sum_xy"]),
            int(r["left_sum_xx"]),
            int(r["left_raw_valid"]),
            int(r["left_raw_a_q16"]) & 0xFFFFFFFF,
            int(r["left_raw_b_q4"]) & 0xFFFFFFFF,
            int(r["left_ema_a_q16"]) & 0xFFFFFFFF,
            int(r["left_ema_b_q4"]) & 0xFFFFFFFF,
            int(r["left_track_valid"]),
            int(r["left_lost_cnt"]),
            int(r["left_solid_run"]),
            int(r["left_double_count"]),
            type_map.get(r["left_frame_type"], 0),
            type_map.get(r["left_voted_type"], 0),
            int(r["left_x_bot"]) & 0xFFFF,
            int(r["left_depart"]),

            int(r["right_n"]),
            int(r["right_sum_y"]),
            int(r["right_sum_yy"]),
            int(r["right_sum_x"]),
            int(r["right_sum_xy"]),
            int(r["right_sum_xx"]),
            int(r["right_raw_valid"]),
            int(r["right_raw_a_q16"]) & 0xFFFFFFFF,
            int(r["right_raw_b_q4"]) & 0xFFFFFFFF,
            int(r["right_ema_a_q16"]) & 0xFFFFFFFF,
            int(r["right_ema_b_q4"]) & 0xFFFFFFFF,
            int(r["right_track_valid"]),
            int(r["right_lost_cnt"]),
            int(r["right_solid_run"]),
            int(r["right_double_count"]),
            type_map.get(r["right_frame_type"], 0),
            type_map.get(r["right_voted_type"], 0),
            int(r["right_x_bot"]) & 0xFFFF,
            int(r["right_depart"]),
        ]
        hex_str = " ".join(f"{v:08X}" for v in fields)
        out_f.write(hex_str + "\n")

# 2. 转换 rows.csv -> rows_ref.hex
with open(rows_csv_path, "r", encoding="utf-8") as f:
    rows_reader = list(csv.DictReader(f))

with open(rows_hex_path, "w", encoding="utf-8") as out_r:
    for r in rows_reader:
        fields = [
            int(r["left_x"]) & 0xFFFF,
            int(r["left_hit"]),
            int(r["left_double"]),
            int(r["right_x"]) & 0xFFFF,
            int(r["right_hit"]),
            int(r["right_double"]),
        ]
        hex_str = " ".join(f"{v:04X}" for v in fields)
        out_r.write(hex_str + "\n")

print(f"Generated {frames_hex_path} ({len(frames_reader)} lines) and {rows_hex_path} ({len(rows_reader)} lines)")
print(f"  frames_ref.hex size: {os.path.getsize(frames_hex_path):,} bytes")
print(f"  rows_ref.hex size:   {os.path.getsize(rows_hex_path):,} bytes")
