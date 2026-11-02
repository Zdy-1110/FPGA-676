# -*- coding: utf-8 -*-
"""FPGA 板级测试向量导出工具 (seg_board)。

读取板级 dump 文件 (f0000.rgb565 ~ f0011.rgb565)，进行 R/B 字段互换：
    p' = ((p & 0x1F) << 11) | (p & 0x07E0) | (p >> 11)
按 60Hz 采样/30fps 源规则，每帧重复两次组成 24 帧序列：
    f0000, f0000, f0001, f0001, ..., f0011, f0011
从模型冷启动状态逐帧调用 Python 定点流式模型 (LaneFPGAModel)，
导出测试向量到 log/lane_fpga/vectors/seg_board/：
- frames.bin: 24 帧 960x540 RGB565 小端 uint16
- rows.csv: 24 帧 x 241 ROI 行候选点
- frames.csv: 24 帧完整统计累加量、原始拟合、EMA平滑、虚实比例、表决与判决
并执行与 export_vectors.py 完全一致的自检校验与 run 统计对比。
"""

import csv
import os
import tempfile
import sys

# 保证根目录在 sys.path
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

import numpy as np

from tools.lane_fpga.model import LaneFPGAModel, load_params
from tools.lane_fpga.export_vectors import compute_decision, get_request, check_segment

VECTORS_ROOT = os.path.abspath(os.path.join(REPO_ROOT, "log", "lane_fpga", "vectors"))
DUMP_DIR = os.path.join(tempfile.gettempdir(), "nesai", "slot0_dump")


def export_board_segment(params):
    seg_name = "seg_board"
    out_dir = os.path.join(VECTORS_ROOT, seg_name)
    os.makedirs(out_dir, exist_ok=True)

    n_dump_frames = 12
    repeat_per_frame = 2
    n_frames = n_dump_frames * repeat_per_frame  # 24 帧

    # 1. 读取 12 个 dump 文件并做 R/B 互换，构建 24 帧序列
    swapped_frames = []
    for i in range(n_dump_frames):
        dump_path = os.path.join(DUMP_DIR, f"f{i:04d}.rgb565")
        if not os.path.exists(dump_path):
            raise FileNotFoundError(f"Dump file not found: {dump_path}")
        raw = np.fromfile(dump_path, dtype="<u2").reshape((540, 960))
        # R/B 字段互换：FPGA 读取时把 bits[4:0] 当 R，bits[15:11] 当 B
        swapped = ((raw & 0x001F) << 11) | (raw & 0x07E0) | ((raw >> 11) & 0x001F)
        for _ in range(repeat_per_frame):
            swapped_frames.append(swapped.astype(np.uint16))

    # 冷启动模型（无任何历史状态）
    model = LaneFPGAModel(params)

    bin_frames = []
    rows_data = []
    frames_data = []
    max_runs_per_frame = []

    y_top = params["y_top"]
    y_bot = params["y_bot"]
    n_rows = y_bot - y_top + 1
    eval_n_rows = max(1, y_bot - params.get("solid_y_top", y_top) + 1)
    depart_margin = params["depart_margin"]
    ego_x = params["ego_x"]

    for f_idx in range(n_frames):
        frame_u16 = swapped_frames[f_idx]
        res = model.process_frame(frame_u16)
        rgb565 = res["rgb565_bin"]  # uint16 (540, 960)
        bin_frames.append(rgb565)

        # 统计本帧每行 run 数量的最大值
        frame_max_runs = max(len(r["runs"]) for r in res["row_candidates"])
        max_runs_per_frame.append(frame_max_runs)

        # 逐行 rows.csv
        row_cands = res["row_candidates"]
        for r in row_cands:
            y = r["y"]
            lx = r["left_cand"] if r["left_cand"] is not None else -1
            lhit = 1 if r["left_cand"] is not None else 0
            ldbl = 1 if r["double_left"] else 0
            rx = r["right_cand"] if r["right_cand"] is not None else -1
            rhit = 1 if r["right_cand"] is not None else 0
            rdbl = 1 if r["double_right"] else 0
            rows_data.append([f_idx, y, lx, lhit, ldbl, rx, rhit, rdbl])

        # 帧统计 frames.csv
        cmd, force = get_request(f_idx)

        # 左侧数据提取
        l_acc = res["acc"]["left"]
        l_fit = res["fit_res"]["left"]
        l_raw_valid = 1 if l_fit["valid"] else 0
        l_raw_a = l_fit["a_q"]
        l_raw_b = l_fit["b_q"]
        l_ema_a = model.left_state.a_smooth_q16 if model.left_state.a_smooth_q16 is not None else 0
        l_ema_b = model.left_state.b_smooth_q4 if model.left_state.b_smooth_q4 is not None else 0
        l_track_valid = 1 if model.left_state.valid else 0
        l_lost_cnt = model.left_state.invalid_count
        l_srun = l_fit["solid_run"]
        l_sflag = 1 if (l_srun * 1000 >= eval_n_rows * int(round(params["solid_run_ratio"] * 1000))) else 0
        l_dcnt = l_fit["double_count"]
        l_dflag = 1 if (l_dcnt * 1000 >= n_rows * int(round(params["double_ratio_thr"] * 1000))) else 0
        l_ftype = res["frame_types"]["left"]
        l_vtype = res["voted_types"]["left"]
        l_x_bot = res["x_bot_l"] if res["x_bot_l"] is not None else -1
        l_depart = 1 if (res["x_bot_l"] is not None and (ego_x - res["x_bot_l"] < depart_margin)) else 0

        # 右侧数据提取
        r_acc = res["acc"]["right"]
        r_fit = res["fit_res"]["right"]
        r_raw_valid = 1 if r_fit["valid"] else 0
        r_raw_a = r_fit["a_q"]
        r_raw_b = r_fit["b_q"]
        r_ema_a = model.right_state.a_smooth_q16 if model.right_state.a_smooth_q16 is not None else 0
        r_ema_b = model.right_state.b_smooth_q4 if model.right_state.b_smooth_q4 is not None else 0
        r_track_valid = 1 if model.right_state.valid else 0
        r_lost_cnt = model.right_state.invalid_count
        r_srun = r_fit["solid_run"]
        r_sflag = 1 if (r_srun * 1000 >= eval_n_rows * int(round(params["solid_run_ratio"] * 1000))) else 0
        r_dcnt = r_fit["double_count"]
        r_dflag = 1 if (r_dcnt * 1000 >= n_rows * int(round(params["double_ratio_thr"] * 1000))) else 0
        r_ftype = res["frame_types"]["right"]
        r_vtype = res["voted_types"]["right"]
        r_x_bot = res["x_bot_r"] if res["x_bot_r"] is not None else -1
        r_depart = 1 if (res["x_bot_r"] is not None and (res["x_bot_r"] - ego_x < depart_margin)) else 0

        decision = compute_decision(cmd, force, l_vtype, l_depart, r_depart)

        frames_data.append([
            f_idx, cmd, force, decision,
            l_acc["n"], l_acc["sum_y"], l_acc["sum_yy"], l_acc["sum_x"], l_acc["sum_xy"], l_acc["sum_xx"],
            l_raw_valid, l_raw_a, l_raw_b, l_ema_a, l_ema_b, l_track_valid, l_lost_cnt,
            l_srun, l_sflag, l_dcnt, l_dflag, l_ftype, l_vtype, l_x_bot, l_depart,
            r_acc["n"], r_acc["sum_y"], r_acc["sum_yy"], r_acc["sum_x"], r_acc["sum_xy"], r_acc["sum_xx"],
            r_raw_valid, r_raw_a, r_raw_b, r_ema_a, r_ema_b, r_track_valid, r_lost_cnt,
            r_srun, r_sflag, r_dcnt, r_dflag, r_ftype, r_vtype, r_x_bot, r_depart
        ])

    # 1. 写入 frames.bin
    bin_path = os.path.join(out_dir, "frames.bin")
    all_bin = np.stack(bin_frames, axis=0)  # (24, 540, 960) uint16
    with open(bin_path, "wb") as fb:
        fb.write(all_bin.astype("<u2").tobytes())

    # 2. 写入 rows.csv
    rows_path = os.path.join(out_dir, "rows.csv")
    with open(rows_path, "w", newline="", encoding="utf-8") as fr:
        writer = csv.writer(fr)
        writer.writerow(["frame", "y", "left_x", "left_hit", "left_double", "right_x", "right_hit", "right_double"])
        writer.writerows(rows_data)

    # 3. 写入 frames.csv
    frames_path = os.path.join(out_dir, "frames.csv")
    with open(frames_path, "w", newline="", encoding="utf-8") as ff:
        writer = csv.writer(ff)
        writer.writerow([
            "frame", "req_cmd", "req_force", "decision",
            "left_n", "left_sum_y", "left_sum_yy", "left_sum_x", "left_sum_xy", "left_sum_xx",
            "left_raw_valid", "left_raw_a_q16", "left_raw_b_q4", "left_ema_a_q16", "left_ema_b_q4",
            "left_track_valid", "left_lost_cnt",
            "left_solid_run", "left_solid_flag", "left_double_count", "left_double_flag",
            "left_frame_type", "left_voted_type", "left_x_bot", "left_depart",
            "right_n", "right_sum_y", "right_sum_yy", "right_sum_x", "right_sum_xy", "right_sum_xx",
            "right_raw_valid", "right_raw_a_q16", "right_raw_b_q4", "right_ema_a_q16", "right_ema_b_q4",
            "right_track_valid", "right_lost_cnt",
            "right_solid_run", "right_solid_flag", "right_double_count", "right_double_flag",
            "right_frame_type", "right_voted_type", "right_x_bot", "right_depart"
        ])
        writer.writerows(frames_data)

    print(f"[{seg_name}] Exported {n_frames} frames to {out_dir}")
    print(f"  frames.bin: {os.path.getsize(bin_path):,} bytes")
    print(f"  rows.csv:   {os.path.getsize(rows_path):,} bytes ({len(rows_data)} rows)")
    print(f"  frames.csv: {os.path.getsize(frames_path):,} bytes ({len(frames_data)} rows)")

    # 4. 自检自校验：重新用导出的 frames.bin 跑一遍模型，对比结果
    seg_info = {"name": seg_name, "n_frames": n_frames}
    check_segment(seg_info, params, bin_path, rows_data, frames_data)

    # 5. 打印 24 帧摘要与 Run 统计对比
    print("=" * 60)
    print("24 帧模型解算结果摘要：")
    print(f"{'Frame':5s} | {'Left n':6s} {'raw_v':5s} {'EMA_a':8s} {'voted':10s} | {'Right n':7s} {'raw_v':5s} {'EMA_a':8s} {'voted':10s} | {'max_runs':8s}")
    print("-" * 75)
    for f in frames_data:
        f_idx = f[0]
        l_n, l_rv, l_ema_a, l_vtype = f[4], f[10], f[13], f[22]
        r_n, r_rv, r_ema_a, r_vtype = f[25], f[31], f[34], f[43]
        m_run = max_runs_per_frame[f_idx]
        print(f"{f_idx:5d} | {l_n:6d} {l_rv:5d} {l_ema_a:8d} {l_vtype:10s} | {r_n:7d} {r_rv:5d} {r_ema_a:8d} {r_vtype:10s} | {m_run:8d}")

    # 与三段原向量的 Run 最大值对比
    compare_run_statistics(params, max(max_runs_per_frame))

    return bin_path, rows_path, frames_path


def export_recover_segment(params):
    """导出恢复测试向量 seg_recover (共 40 帧)。

    前 16 帧全黑 (RGB565 全 0)，后接 seg_board 的 24 帧。
    从模型复位冷启动状态开始逐帧导出。
    """
    seg_name = "seg_recover"
    out_dir = os.path.join(VECTORS_ROOT, seg_name)
    os.makedirs(out_dir, exist_ok=True)

    n_black = 16
    n_board = 24
    n_frames = n_black + n_board

    # 1. 准备 40 帧图像数据
    all_frames = []
    # 16 帧全黑
    black = np.zeros((540, 960), dtype=np.uint16)
    for _ in range(n_black):
        all_frames.append(black)

    # 24 帧 seg_board (12 个 dump 文件，每帧重复两次，做 R/B 互换)
    for i in range(12):
        dump_path = os.path.join(DUMP_DIR, f"f{i:04d}.rgb565")
        if not os.path.exists(dump_path):
            raise FileNotFoundError(f"Dump file not found: {dump_path}")
        raw = np.fromfile(dump_path, dtype="<u2").reshape((540, 960))
        swapped = ((raw & 0x001F) << 11) | (raw & 0x07E0) | ((raw >> 11) & 0x001F)
        for _ in range(2):
            all_frames.append(swapped.astype(np.uint16))

    # 冷启动模型
    model = LaneFPGAModel(params)

    bin_frames = []
    rows_data = []
    frames_data = []

    y_top = params["y_top"]
    y_bot = params["y_bot"]
    n_rows = y_bot - y_top + 1
    eval_n_rows = max(1, y_bot - params.get("solid_y_top", y_top) + 1)
    depart_margin = params["depart_margin"]
    ego_x = params["ego_x"]

    for f_idx in range(n_frames):
        frame_u16 = all_frames[f_idx]
        res = model.process_frame(frame_u16)
        rgb565 = res["rgb565_bin"]
        bin_frames.append(rgb565)

        # 逐行 rows.csv
        for r in res["row_candidates"]:
            y = r["y"]
            lx = r["left_cand"] if r["left_cand"] is not None else -1
            lhit = 1 if r["left_cand"] is not None else 0
            ldbl = 1 if r["double_left"] else 0
            rx = r["right_cand"] if r["right_cand"] is not None else -1
            rhit = 1 if r["right_cand"] is not None else 0
            rdbl = 1 if r["double_right"] else 0
            rows_data.append([f_idx, y, lx, lhit, ldbl, rx, rhit, rdbl])

        # 帧统计 frames.csv
        cmd, force = get_request(f_idx)

        l_acc = res["acc"]["left"]
        l_fit = res["fit_res"]["left"]
        l_raw_valid = 1 if l_fit["valid"] else 0
        l_raw_a = l_fit["a_q"]
        l_raw_b = l_fit["b_q"]
        l_ema_a = model.left_state.a_smooth_q16 if model.left_state.a_smooth_q16 is not None else 0
        l_ema_b = model.left_state.b_smooth_q4 if model.left_state.b_smooth_q4 is not None else 0
        l_track_valid = 1 if model.left_state.valid else 0
        l_lost_cnt = model.left_state.invalid_count
        l_srun = l_fit["solid_run"]
        l_sflag = 1 if (l_srun * 1000 >= eval_n_rows * int(round(params["solid_run_ratio"] * 1000))) else 0
        l_dcnt = l_fit["double_count"]
        l_dflag = 1 if (l_dcnt * 1000 >= n_rows * int(round(params["double_ratio_thr"] * 1000))) else 0
        l_ftype = res["frame_types"]["left"]
        l_vtype = res["voted_types"]["left"]
        l_x_bot = res["x_bot_l"] if res["x_bot_l"] is not None else -1
        l_depart = 1 if (res["x_bot_l"] is not None and (ego_x - res["x_bot_l"] < depart_margin)) else 0

        r_acc = res["acc"]["right"]
        r_fit = res["fit_res"]["right"]
        r_raw_valid = 1 if r_fit["valid"] else 0
        r_raw_a = r_fit["a_q"]
        r_raw_b = r_fit["b_q"]
        r_ema_a = model.right_state.a_smooth_q16 if model.right_state.a_smooth_q16 is not None else 0
        r_ema_b = model.right_state.b_smooth_q4 if model.right_state.b_smooth_q4 is not None else 0
        r_track_valid = 1 if model.right_state.valid else 0
        r_lost_cnt = model.right_state.invalid_count
        r_srun = r_fit["solid_run"]
        r_sflag = 1 if (r_srun * 1000 >= eval_n_rows * int(round(params["solid_run_ratio"] * 1000))) else 0
        r_dcnt = r_fit["double_count"]
        r_dflag = 1 if (r_dcnt * 1000 >= n_rows * int(round(params["double_ratio_thr"] * 1000))) else 0
        r_ftype = res["frame_types"]["right"]
        r_vtype = res["voted_types"]["right"]
        r_x_bot = res["x_bot_r"] if res["x_bot_r"] is not None else -1
        r_depart = 1 if (res["x_bot_r"] is not None and (res["x_bot_r"] - ego_x < depart_margin)) else 0

        decision = compute_decision(cmd, force, l_vtype, l_depart, r_depart)

        frames_data.append([
            f_idx, cmd, force, decision,
            l_acc["n"], l_acc["sum_y"], l_acc["sum_yy"], l_acc["sum_x"], l_acc["sum_xy"], l_acc["sum_xx"],
            l_raw_valid, l_raw_a, l_raw_b, l_ema_a, l_ema_b, l_track_valid, l_lost_cnt,
            l_srun, l_sflag, l_dcnt, l_dflag, l_ftype, l_vtype, l_x_bot, l_depart,
            r_acc["n"], r_acc["sum_y"], r_acc["sum_yy"], r_acc["sum_x"], r_acc["sum_xy"], r_acc["sum_xx"],
            r_raw_valid, r_raw_a, r_raw_b, r_ema_a, r_ema_b, r_track_valid, r_lost_cnt,
            r_srun, r_sflag, r_dcnt, r_dflag, r_ftype, r_vtype, r_x_bot, r_depart
        ])

    # 1. 写入 frames.bin
    bin_path = os.path.join(out_dir, "frames.bin")
    all_bin = np.stack(bin_frames, axis=0)  # (40, 540, 960) uint16
    with open(bin_path, "wb") as fb:
        fb.write(all_bin.astype("<u2").tobytes())

    # 2. 写入 rows.csv
    rows_path = os.path.join(out_dir, "rows.csv")
    with open(rows_path, "w", newline="", encoding="utf-8") as fr:
        writer = csv.writer(fr)
        writer.writerow(["frame", "y", "left_x", "left_hit", "left_double", "right_x", "right_hit", "right_double"])
        writer.writerows(rows_data)

    # 3. 写入 frames.csv
    frames_path = os.path.join(out_dir, "frames.csv")
    with open(frames_path, "w", newline="", encoding="utf-8") as ff:
        writer = csv.writer(ff)
        writer.writerow([
            "frame", "req_cmd", "req_force", "decision",
            "left_n", "left_sum_y", "left_sum_yy", "left_sum_x", "left_sum_xy", "left_sum_xx",
            "left_raw_valid", "left_raw_a_q16", "left_raw_b_q4", "left_ema_a_q16", "left_ema_b_q4",
            "left_track_valid", "left_lost_cnt",
            "left_solid_run", "left_solid_flag", "left_double_count", "left_double_flag",
            "left_frame_type", "left_voted_type", "left_x_bot", "left_depart",
            "right_n", "right_sum_y", "right_sum_yy", "right_sum_x", "right_sum_xy", "right_sum_xx",
            "right_raw_valid", "right_raw_a_q16", "right_raw_b_q4", "right_ema_a_q16", "right_ema_b_q4",
            "right_track_valid", "right_lost_cnt",
            "right_solid_run", "right_solid_flag", "right_double_count", "right_double_flag",
            "right_frame_type", "right_voted_type", "right_x_bot", "right_depart"
        ])
        writer.writerows(frames_data)

    print(f"[{seg_name}] Exported {n_frames} frames to {out_dir}")
    print(f"  frames.bin: {os.path.getsize(bin_path):,} bytes")
    print(f"  rows.csv:   {os.path.getsize(rows_path):,} bytes ({len(rows_data)} rows)")
    print(f"  frames.csv: {os.path.getsize(frames_path):,} bytes ({len(frames_data)} rows)")

    # 4. 自检自校验
    seg_info = {"name": seg_name, "n_frames": n_frames}
    check_segment(seg_info, params, bin_path, rows_data, frames_data)

    return bin_path, rows_path, frames_path


def compare_run_statistics(params, board_max_runs):
    print("=" * 60)
    print("每行 Run 数量统计对比 (RTL Run Buffer 上限 = 127)：")
    print(f"  - seg_board (实板序列 24 帧): 每行最大 Run 数 = {board_max_runs} (未超 127 缓冲上限: {board_max_runs <= 127})")

    for seg in ["seg_A_solid", "seg_B_dashed", "seg_C_double_yellow"]:
        bin_path = os.path.join(VECTORS_ROOT, seg, "frames.bin")
        if os.path.exists(bin_path):
            raw_data = np.fromfile(bin_path, dtype="<u2").reshape((60, 540, 960))
            check_model = LaneFPGAModel(params)
            seg_max = 0
            for f in range(60):
                res = check_model.process_frame(raw_data[f])
                f_max = max(len(r["runs"]) for r in res["row_candidates"])
                seg_max = max(seg_max, f_max)
            print(f"  - {seg:20s}: 每行最大 Run 数 = {seg_max} (未超 127: {seg_max <= 127})")
    print("=" * 60)


def main():
    params = load_params()
    export_board_segment(params)
    export_recover_segment(params)


if __name__ == "__main__":
    main()
