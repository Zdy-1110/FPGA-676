# -*- coding: utf-8 -*-
"""定点 BEV 黄金模型评测脚本（F_fixed）。

复用 J_cal 的视频、标定初值与评估口径，注入定点化 BEV + 脊线 + 直方图模型，
生成 video_review/ref_runs/F_fixed_eval.md，并对比 J_cal 评估结果。
"""

import argparse
import csv
import glob
import json
import os
import sys
import time
from collections import defaultdict

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from video_io import iter_frames, video_id
from lane_bev import LaneBEV
from decide_ref import decide_sig, decide_lane, line_class
import bev_fixed

DEFAULT_SRC = r"E:\Project\nesai2026\video_review\src"
DEFAULT_OUT = r"E:\Project\nesai2026\video_review\ref_runs\F_fixed"
DEFAULT_J_CAL = r"E:\Project\nesai2026\video_review\ref_runs\J_cal"
DEFAULT_PARAMS = r"E:\Project\nesai2026\tools\ref_algo\params.json"
DEFAULT_FFMPEG = r"D:\Program Files\FormatFactory\ffmpeg.exe"
DEFAULT_GT_DIR = r"E:\Project\nesai2026\video_review\gt"
DEFAULT_TESTCASES = r"E:\Project\nesai2026\video_review\gt\out\testcases.csv"
DEFAULT_OUT_MD = r"E:\Project\nesai2026\video_review\ref_runs\F_fixed_eval.md"
DEFAULT_OUT_CSV = r"E:\Project\nesai2026\video_review\ref_runs\F_fixed_cases.csv"

CSV_COLS = [
    "frame", "t", "sig_left", "sig_straight", "sig_right",
    "raw_left", "raw_straight", "raw_right", "n_lights", "lights",
    "left_line", "right_line", "left_cov", "right_cov",
    "ego_motion", "motion_score"
]
LANE_DBG_COLS = [
    "frame", "t", "fallback", "n_cands", "cands", "uL", "uR",
    "d", "p", "score", "d_est", "p_est"
]


def _fmt2(v):
    return "" if v is None else f"{float(v):.2f}"


class FixedBEVWrapper:
    """包装 LaneBEV，将其 _marking_bev 替换为定点模型，同时记录与浮点参考的比对统计。"""

    def __init__(self, lane_bev_instance, use_green=False):
        self.lane = lane_bev_instance
        self.use_green = use_green
        self.orig_marking_bev = lane_bev_instance._marking_bev
        self.stats = []  # (frame_idx, t, m_iou, y_iou, peak_diff)

        # 注入方法
        self.lane._marking_bev = self.fixed_marking_bev

    def fixed_marking_bev(self, frame):
        # 1. 浮点参考结果（用于对比）
        ref_m, ref_y, ref_gray = self.orig_marking_bev(frame)

        # 2. 定点计算
        lane = self.lane
        pb = lane.pb
        p = lane.p
        w, h = int(pb["w"]), int(pb["h"])

        # 生成定点行表
        tbl = bev_fixed.make_row_table(
            (lane.vp_x, lane.vp_y), lane.y_bot, lane.bev_yt,
            W=lane.W, H=lane.H, w=w, h=h
        )

        # 准备图像输入（亮度与色度）
        if self.use_green:
            Yplane = frame[:, :, 1]  # BGR 的 G 通道测试
        else:
            Yplane = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)  # 亮度 Y 平面

        yuv = cv2.cvtColor(frame, cv2.COLOR_BGR2YUV)
        UVplane = np.empty((lane.H // 2, lane.W), dtype=np.uint8)
        UVplane[:, 0::2] = yuv[::2, ::2, 1]
        UVplane[:, 1::2] = yuv[::2, ::2, 2]

        bev_y_img, bev_u_img, bev_v_img = bev_fixed.bev_sample_nv12(
            Yplane, UVplane, tbl,
            W=lane.W, H=lane.H, w=w, h=h, frac_bits=6
        )

        fix_m, fix_y, fix_w = bev_fixed.ridge(
            bev_y_img, bev_u_img, bev_v_img,
            ridge_d=pb["ridge_d"], ridge_delta=pb["ridge_delta"], y_min=p["y_min"]
        )

        # 3. 统计逐帧一致性
        inter_m = (ref_m & fix_m).sum()
        union_m = (ref_m | fix_m).sum()
        m_iou = float(inter_m / union_m) if union_m > 0 else 1.0

        inter_y = (ref_y & fix_y).sum()
        union_y = (ref_y | fix_y).sum()
        y_iou = float(inter_y / union_y) if union_y > 0 else 1.0

        h0 = int(h * (1.0 - pb.get("hist_rows_frac", 1.0)))
        ref_h = ref_m[h0:, :].sum(axis=0)
        fix_h = bev_fixed.histogram(fix_m, rows_frac=pb.get("hist_rows_frac", 1.0))
        p_ref = int(np.argmax(ref_h)) if ref_h.max() > 0 else 0
        p_fix = int(np.argmax(fix_h)) if fix_h.max() > 0 else 0
        peak_diff = abs(p_ref - p_fix)

        self.stats.append({
            "m_iou": m_iou,
            "y_iou": y_iou,
            "peak_diff": peak_diff,
            "p_ref": p_ref,
            "p_fix": p_fix
        })

        return fix_m, fix_y, bev_y_img


def load_j_cal_states(j_cal_sub_dir):
    """读取已有的 J_cal states.csv，用于复用不变的 tl 与 motion 输出。"""
    path = os.path.join(j_cal_sub_dir, "states.csv")
    if not os.path.isfile(path):
        return None
    rows = []
    with open(path, "r", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            rows.append(r)
    return rows


def process_video_fixed(video_path, out_dir, j_cal_sub_dir, params, step=3,
                        ffmpeg=DEFAULT_FFMPEG, use_green=False):
    """对单个视频执行定点化 BEV 处理，生成 states.csv 与 calib.json。"""
    os.makedirs(out_dir, exist_ok=True)
    vid = video_id(video_path)
    W, H = 1920, 1080
    fps_eff = 30.0 / step

    # 1. 标定参数继承 J_cal
    calib_json_path = os.path.join(j_cal_sub_dir, "calib.json")
    if os.path.isfile(calib_json_path):
        with open(calib_json_path, "r", encoding="utf-8") as f:
            calib = json.load(f)
    else:
        raise FileNotFoundError(f"Missing J_cal calib.json at {calib_json_path}")

    lane = LaneBEV(params["lane"], params["bev"], fps_eff, W, H)
    lane.y_top = int(calib["y_top"])
    lane.y_bot = int(calib["y_bot"])
    lane.vp_x = float(calib["vp_x"])
    lane.vp_y = float(calib["vp_y"])
    lane.vp_frozen = not params.get("bev", {}).get("refine_after_manual", False)

    wrapper = FixedBEVWrapper(lane, use_green=use_green)

    # 2. 读取 J_cal 既有的 tl / motion 数据以保证基准一致性
    j_states = load_j_cal_states(j_cal_sub_dir)
    j_dict = {}
    if j_states:
        for r in j_states:
            j_dict[int(r["frame"])] = r

    csv_path = os.path.join(out_dir, "states.csv")
    dbg_path = os.path.join(out_dir, "lane_debug.csv")

    gen = iter_frames(video_path, ffmpeg, step, max_seconds=0.0, fps=30.0, w=W, h=H)

    with open(csv_path, "w", newline="", encoding="utf-8") as fh_csv, \
         open(dbg_path, "w", newline="", encoding="utf-8") as fh_dbg:
        wr_csv = csv.writer(fh_csv)
        wr_csv.writerow(CSV_COLS)
        wr_dbg = csv.writer(fh_dbg)
        wr_dbg.writerow(LANE_DBG_COLS)

        for i, t, frame in gen:
            # 运行定点车道线检测
            lane_res = lane.detect(frame)

            # 写入 lane_debug.csv
            pd = lane_res.get("pair_dbg")
            if pd is not None:
                wr_dbg.writerow([
                    i, f"{t:.2f}", bool(pd.get("fallback")),
                    pd.get("n_cands"), pd.get("cands") or "",
                    _fmt2(pd.get("uL")), _fmt2(pd.get("uR")),
                    _fmt2(pd.get("d")), _fmt2(pd.get("p")),
                    _fmt2(pd.get("score")), _fmt2(pd.get("d_est")),
                    _fmt2(pd.get("p_est"))
                ])

            # 整合 states 行
            j_row = j_dict.get(i)
            if j_row:
                sig_left = j_row["sig_left"]
                sig_straight = j_row["sig_straight"]
                sig_right = j_row["sig_right"]
                raw_left = j_row["raw_left"]
                raw_straight = j_row["raw_straight"]
                raw_right = j_row["raw_right"]
                n_lights = j_row["n_lights"]
                lights = j_row["lights"]
                ego_motion = j_row["ego_motion"]
                motion_score = j_row["motion_score"]
            else:
                sig_left = sig_straight = sig_right = "none"
                raw_left = raw_straight = raw_right = "none"
                n_lights = 0
                lights = ""
                ego_motion = "stopped"
                motion_score = "0.000"

            wr_csv.writerow([
                i, f"{t:.3f}", sig_left, sig_straight, sig_right,
                raw_left, raw_straight, raw_right, n_lights, lights,
                lane_res["left_line"], lane_res["right_line"],
                f"{lane_res['left_cov']:.3f}",
                f"{lane_res['right_cov']:.3f}",
                ego_motion, motion_score
            ])

    # 保存 calib.json
    with open(os.path.join(out_dir, "calib.json"), "w", encoding="utf-8") as f:
        out_calib = dict(calib)
        out_calib["bev_fixed"] = True
        out_calib["use_green"] = use_green
        json.dump(out_calib, f, indent=2)

    return wrapper.stats


def run_evaluation(runs_dir, gt_dir, testcases, out_md, out_csv, all_stats):
    """调用原评测逻辑生成报告，并追加定点模型一致性统计分析。"""
    import subprocess
    cmd = [
        sys.executable, "-I",
        os.path.join(os.path.dirname(__file__), "eval_ref.py"),
        "--runs-dir", runs_dir,
        "--gt-dir", gt_dir,
        "--testcases", testcases,
        "--out-md", out_md,
        "--out-csv", out_csv
    ]
    ret = subprocess.run(cmd, capture_output=True, text=True)
    if ret.returncode != 0:
        print("eval_ref.py failed:", ret.stderr)
        return ret.returncode

    # 追加定点模型统计分析到报告末尾
    all_m_ious = []
    all_y_ious = []
    all_peak_diffs = []
    vid_summary = {}

    for vid, stats in all_stats.items():
        if not stats:
            continue
        m_ious = [s["m_iou"] for s in stats]
        y_ious = [s["y_iou"] for s in stats]
        p_diffs = [s["peak_diff"] for s in stats]
        all_m_ious.extend(m_ious)
        all_y_ious.extend(y_ious)
        all_peak_diffs.extend(p_diffs)
        vid_summary[vid] = {
            "n": len(stats),
            "m_iou": float(np.mean(m_ious)),
            "m_iou_p90": float(np.percentile(m_ious, 10)),  # 10% 分位数（最差 10%）
            "peak_diff_mean": float(np.mean(p_diffs)),
            "peak_diff_exact": float((np.array(p_diffs) == 0).mean() * 100.0),
            "peak_diff_le2": float((np.array(p_diffs) <= 2).mean() * 100.0)
        }

    overall_m_iou = float(np.mean(all_m_ious)) if all_m_ious else 0.0
    overall_p_diff = float(np.mean(all_peak_diffs)) if all_peak_diffs else 0.0
    overall_exact = float((np.array(all_peak_diffs) == 0).mean() * 100.0) if all_peak_diffs else 0.0
    overall_le2 = float((np.array(all_peak_diffs) <= 2).mean() * 100.0) if all_peak_diffs else 0.0

    extra_section = [
        "\n\n## 三、定点黄金模型与浮点参考一致性统计\n\n",
        f"- 评测帧数：{len(all_m_ious)} 帧\n",
        f"- 标线掩膜（bev_m）像素级平均 IoU：{overall_m_iou:.4f}\n",
        f"- 列直方图峰值位置平均偏差：{overall_p_diff:.2f} px（精确重合率 {overall_exact:.1f}%，误差 ≤ 2 px 占比 {overall_le2:.1f}%）\n\n",
        "### 各视频掩膜 IoU 与直方图峰值差\n\n",
        "| video | 帧数 | 掩膜平均 IoU | 掩膜 P10 IoU | 峰值平均偏差 (px) | 峰值精确重合率 | 峰值偏差 ≤ 2 px |\n",
        "| --- | --- | --- | --- | --- | --- | --- |\n"
    ]
    for vid, vs in sorted(vid_summary.items()):
        extra_section.append(
            f"| {vid} | {vs['n']} | {vs['m_iou']:.4f} | {vs['m_iou_p90']:.4f} | "
            f"{vs['peak_diff_mean']:.2f} | {vs['peak_diff_exact']:.1f}% | {vs['peak_diff_le2']:.1f}% |\n"
        )

    with open(out_md, "a", encoding="utf-8") as f:
        f.writelines(extra_section)

    return 0


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=DEFAULT_SRC)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--j-cal-dir", default=DEFAULT_J_CAL)
    ap.add_argument("--params", default=DEFAULT_PARAMS)
    ap.add_argument("--ffmpeg", default=DEFAULT_FFMPEG)
    ap.add_argument("--step", type=int, default=3)
    ap.add_argument("--gt-dir", default=DEFAULT_GT_DIR)
    ap.add_argument("--testcases", default=DEFAULT_TESTCASES)
    ap.add_argument("--out-md", default=DEFAULT_OUT_MD)
    ap.add_argument("--out-csv", default=DEFAULT_OUT_CSV)
    ap.add_argument("--use-green", action="store_true", help="测试绿色通道输入而不是 Y 平面")
    args = ap.parse_args(argv)

    with open(args.params, "r", encoding="utf-8") as f:
        params = json.load(f)

    vids = sorted(glob.glob(os.path.join(args.src, "video_20260929_*.mp4")))
    all_stats = {}

    t0_all = time.perf_counter()
    for vpath in vids:
        vid = video_id(vpath)
        j_sub = os.path.join(args.j_cal_dir, vid)
        out_sub = os.path.join(args.out, vid)
        print(f"[{vid}] Processing fixed-point BEV...")
        t0 = time.perf_counter()
        stats = process_video_fixed(vpath, out_sub, j_sub, params, step=args.step,
                                    ffmpeg=args.ffmpeg, use_green=args.use_green)
        dt = time.perf_counter() - t0
        all_stats[vid] = stats
        print(f"[{vid}] Done in {dt:.1f}s ({len(stats)} frames)")

    print("Running evaluation...")
    ret = run_evaluation(args.out, args.gt_dir, args.testcases, args.out_md, args.out_csv, all_stats)
    dt_total = time.perf_counter() - t0_all
    print(f"All finished in {dt_total:.1f}s, exit code: {ret}")
    return ret


if __name__ == "__main__":
    sys.exit(main())



