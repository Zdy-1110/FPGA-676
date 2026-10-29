# -*- coding: utf-8 -*-
"""FPGA 测试向量导出工具。

导出 3 段 x 60 帧测试向量供 RTL Testbench 逐帧比对：
- seg_A_solid: 112507 白实线时段 (f285..f344, 60 帧)
- seg_B_dashed: 113343 虚线时段 (f60..f119, 60 帧)
- seg_C_double_yellow: 113539 双黄线时段 (f1110..f1169, 60 帧)

每段包含：
- frames.bin: 60 帧 960x540 RGB565 小端 uint16
- rows.csv: 60 帧 x 241 ROI 行候选点
- frames.csv: 60 帧完整统计累加量、原始拟合、EMA平滑、虚实比例、表决与判决
并进行自检校验。
"""

import csv
import json
import os
import sys

# 保证根目录在 sys.path
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

import numpy as np
import cv2

from tools.lane_fpga.model import LaneFPGAModel, load_params

VECTORS_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "log", "lane_fpga", "vectors"))

SEGS = [
    {
        "name": "seg_A_solid",
        "video": "video_review/src/video_20260929_112507.mp4",
        "start_frame": 285,
        "n_frames": 60,
        "desc": "112507 白实线时段 (f285..f344, 对应 LANE-112507-02)",
    },
    {
        "name": "seg_B_dashed",
        "video": "video_review/src/video_20260929_113343.mp4",
        "start_frame": 60,
        "n_frames": 60,
        "desc": "113343 虚线时段 (f60..f119, 对应 LANE-113343-03)",
    },
    {
        "name": "seg_C_double_yellow",
        "video": "video_review/src/video_20260929_113539.mp4",
        "start_frame": 1110,
        "n_frames": 60,
        "desc": "113539 双黄线时段 (f1110..f1169, 对应 LANE-113539-04)",
    },
]


def get_request(f_idx):
    """请求表：
    0-19 帧: 无请求 (NONE)
    20-39 帧: 左转请求 (TURN_LEFT, 非强制 force=0)
    40-59 帧: 强制左变道 (FORCE_LEFT, 强制 force=1)
    """
    if f_idx < 20:
        return "NONE", 0
    elif f_idx < 40:
        return "TURN_LEFT", 0
    else:
        return "FORCE_LEFT", 1


def compute_decision(cmd, force, voted_type_left, depart_left, depart_right):
    """根据请求表计算最终硬件输出指令 (0: KEEP, 1: ALLOW, 2: ALARM)。"""
    if cmd == "NONE":
        # 直行保持无转向指令，若偏离则告警
        if depart_left or depart_right:
            return 2  # ALARM
        return 0  # KEEP
    elif cmd == "TURN_LEFT":
        # 左转向（非强制）
        if voted_type_left in ("white_dashed", "yellow_dashed", "dashed"):
            if depart_left:
                return 2  # ALARM
            return 1  # ALLOW
        return 0  # KEEP
    elif cmd == "FORCE_LEFT":
        # 强制左变道
        if voted_type_left in ("white_dashed", "yellow_dashed", "dashed"):
            return 1  # ALLOW
        return 2  # ALARM
    return 0


def export_segment(seg_info, params):
    seg_name = seg_info["name"]
    out_dir = os.path.join(VECTORS_ROOT, seg_name)
    os.makedirs(out_dir, exist_ok=True)

    video_path = os.path.abspath(seg_info["video"])
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {video_path}")

    start_frame = seg_info["start_frame"]
    n_frames = seg_info["n_frames"]
    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame)

    # 冷启动模型（无任何历史状态）
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
        ret, frame_bgr = cap.read()
        if not ret:
            raise RuntimeError(f"Failed to read frame {start_frame + f_idx} from {video_path}")

        res = model.process_frame(frame_bgr)
        rgb565 = res["rgb565_bin"]  # uint16 (540, 960)
        bin_frames.append(rgb565)

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

    cap.release()

    # 1. 写入 frames.bin
    bin_path = os.path.join(out_dir, "frames.bin")
    all_bin = np.stack(bin_frames, axis=0)  # (60, 540, 960) uint16
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
    check_segment(seg_info, params, bin_path, rows_data, frames_data)


def check_segment(seg_info, params, bin_path, exp_rows, exp_frames):
    """自检函数：读取导出的 frames.bin 跑模型，与导出的 CSV 严格比对。"""
    seg_name = seg_info["name"]
    raw_data = np.fromfile(bin_path, dtype="<u2").reshape((seg_info["n_frames"], 540, 960))

    check_model = LaneFPGAModel(params)
    n_frames = seg_info["n_frames"]
    y_top = params["y_top"]
    y_bot = params["y_bot"]
    n_rows = y_bot - y_top + 1
    eval_n_rows = max(1, y_bot - params.get("solid_y_top", y_top) + 1)
    depart_margin = params["depart_margin"]
    ego_x = params["ego_x"]

    row_idx = 0
    for f_idx in range(n_frames):
        frame_u16 = raw_data[f_idx]
        res = check_model.process_frame(frame_u16)

        # 检查 rows
        for r in res["row_candidates"]:
            y = r["y"]
            lx = r["left_cand"] if r["left_cand"] is not None else -1
            lhit = 1 if r["left_cand"] is not None else 0
            ldbl = 1 if r["double_left"] else 0
            rx = r["right_cand"] if r["right_cand"] is not None else -1
            rhit = 1 if r["right_cand"] is not None else 0
            rdbl = 1 if r["double_right"] else 0

            exp_r = exp_rows[row_idx]
            assert [f_idx, y, lx, lhit, ldbl, rx, rhit, rdbl] == exp_r, (
                f"Row mismatch at frame {f_idx}, y {y}: got {[f_idx, y, lx, lhit, ldbl, rx, rhit, rdbl]}, exp {exp_r}"
            )
            row_idx += 1

        # 检查 frames
        cmd, force = get_request(f_idx)
        l_acc = res["acc"]["left"]
        l_fit = res["fit_res"]["left"]
        l_raw_valid = 1 if l_fit["valid"] else 0
        l_raw_a = l_fit["a_q"]
        l_raw_b = l_fit["b_q"]
        l_ema_a = check_model.left_state.a_smooth_q16 if check_model.left_state.a_smooth_q16 is not None else 0
        l_ema_b = check_model.left_state.b_smooth_q4 if check_model.left_state.b_smooth_q4 is not None else 0
        l_track_valid = 1 if check_model.left_state.valid else 0
        l_lost_cnt = check_model.left_state.invalid_count
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
        r_ema_a = check_model.right_state.a_smooth_q16 if check_model.right_state.a_smooth_q16 is not None else 0
        r_ema_b = check_model.right_state.b_smooth_q4 if check_model.right_state.b_smooth_q4 is not None else 0
        r_track_valid = 1 if check_model.right_state.valid else 0
        r_lost_cnt = check_model.right_state.invalid_count
        r_srun = r_fit["solid_run"]
        r_sflag = 1 if (r_srun * 1000 >= eval_n_rows * int(round(params["solid_run_ratio"] * 1000))) else 0
        r_dcnt = r_fit["double_count"]
        r_dflag = 1 if (r_dcnt * 1000 >= n_rows * int(round(params["double_ratio_thr"] * 1000))) else 0
        r_ftype = res["frame_types"]["right"]
        r_vtype = res["voted_types"]["right"]
        r_x_bot = res["x_bot_r"] if res["x_bot_r"] is not None else -1
        r_depart = 1 if (res["x_bot_r"] is not None and (res["x_bot_r"] - ego_x < depart_margin)) else 0

        decision = compute_decision(cmd, force, l_vtype, l_depart, r_depart)

        act_frame_line = [
            f_idx, cmd, force, decision,
            l_acc["n"], l_acc["sum_y"], l_acc["sum_yy"], l_acc["sum_x"], l_acc["sum_xy"], l_acc["sum_xx"],
            l_raw_valid, l_raw_a, l_raw_b, l_ema_a, l_ema_b, l_track_valid, l_lost_cnt,
            l_srun, l_sflag, l_dcnt, l_dflag, l_ftype, l_vtype, l_x_bot, l_depart,
            r_acc["n"], r_acc["sum_y"], r_acc["sum_yy"], r_acc["sum_x"], r_acc["sum_xy"], r_acc["sum_xx"],
            r_raw_valid, r_raw_a, r_raw_b, r_ema_a, r_ema_b, r_track_valid, r_lost_cnt,
            r_srun, r_sflag, r_dcnt, r_dflag, r_ftype, r_vtype, r_x_bot, r_depart
        ]
        exp_frame_line = exp_frames[f_idx]
        assert act_frame_line == exp_frame_line, (
            f"Frame mismatch at frame {f_idx}:\n Got: {act_frame_line}\n Exp: {exp_frame_line}"
        )

    print(f"  [PASS] Self-check: 100% bit-exact match on {seg_name} ({n_frames} frames)!\n")


def main():
    params = load_params()
    print("=" * 60)
    print("Exporting FPGA Test Vectors (3 segments x 60 frames)")
    print("=" * 60)
    for seg in SEGS:
        export_segment(seg, params)
    print("All 3 segments successfully exported and verified!")


if __name__ == "__main__":
    main()
