# -*- coding: utf-8 -*-
"""FPGA 定点流式车道线模型评测脚本。

在 32 个 LANE 测试用例上按参考感知同一评估口径（复用 testcases.csv 与 decide_ref.py 判定函数）：
- 评测 4 个相关视频（112507, 113343, 113452, 113539）。
- 输出与 ref_algo 17/32 的逐用例对比表到 tools/lane_fpga/eval_report.md。
- 为每个用例存一张代表帧叠加图（候选点、拟合线、类型、决策）到 log/lane_fpga/vis/。
- 末尾输出 RTL 硬件资源估计（寄存器、乘法器、除法器）。
"""

import argparse
import csv
import glob
import json
import os
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime

import numpy as np

# 自动挂载依赖
try:
    import cv2
except ImportError:
    site_pkg = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..", ".venv_yolo", "Lib", "site-packages")
    )
    if os.path.exists(site_pkg):
        sys.path.insert(0, site_pkg)
    import cv2

LANE_FPGA_DIR = os.path.abspath(os.path.dirname(__file__))
if LANE_FPGA_DIR not in sys.path:
    sys.path.insert(0, LANE_FPGA_DIR)

# 导入参考判决接口
REF_ALGO_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "ref_algo"))
if REF_ALGO_DIR not in sys.path:
    sys.path.insert(0, REF_ALGO_DIR)

from decide_ref import decide_lane, line_class  # noqa: E402
from model import LaneFPGAModel, load_params  # noqa: E402

DEFAULT_SRC = r"E:\Project\nesai2026\video_review\src"
DEFAULT_TESTCASES = r"E:\Project\nesai2026\video_review\gt\out\testcases.csv"
DEFAULT_OUT_MD = os.path.join(os.path.dirname(__file__), "eval_report.md")
DEFAULT_VIS_DIR = r"E:\Project\nesai2026\log\lane_fpga\vis"


def load_lane_testcases(csv_path):
    cases = []
    with open(csv_path, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            if (r.get("category") or "").strip() == "LANE":
                cases.append(r)
    return cases


def expected_code(expected):
    e = expected or ""
    if "报警" in e:
        return "ALARM"
    if "允许" in e:
        return "ALLOW"
    if "保持直行" in e:
        return "KEEP"
    return ""


def run_video_fpga(video_path, model, step=1):
    """逐帧运行 FPGA 定点模型，记录每一帧状态。"""
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS)
    if fps <= 0:
        fps = 30.0

    frames_state = []
    vis_cache = {}  # 缓存某些代表帧的绘制图

    frame_idx = 0
    model.reset()

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        if frame_idx % step == 0:
            t = frame_idx / fps
            res = model.process_frame(frame)
            rec = {
                "frame": frame_idx,
                "t": t,
                "left_line": res["voted_types"]["left"],
                "right_line": res["voted_types"]["right"],
                "depart_warning": res["depart_warning"],
                "res": res,
            }
            frames_state.append(rec)
        frame_idx += 1

    cap.release()
    return frames_state, fps


def draw_vis_frame(rec, case_info=None):
    """为单帧生成可视化效果图。"""
    res = rec["res"]
    img = res["frame_960"].copy()
    y_top = res["row_candidates"][0]["y"]
    y_bot = res["row_candidates"][-1]["y"]

    # 1. 绘制候选点
    for r in res["row_candidates"]:
        y = r["y"]
        if r["left_cand"] is not None:
            color = (255, 255, 0) if r["double_left"] else (255, 200, 0)
            cv2.circle(img, (r["left_cand"], y), 1, color, -1)
        if r["right_cand"] is not None:
            color = (255, 0, 255) if r["double_right"] else (0, 255, 255)
            cv2.circle(img, (r["right_cand"], y), 1, color, -1)

    # 2. 绘制拟合线
    for side, color, text_x in (("left", (0, 255, 0), 30), ("right", (0, 165, 255), 700)):
        fit = res["fit_res"][side]
        v_type = res["voted_types"][side]
        if fit["valid"]:
            a = fit["a_flt"]
            b = fit["b_flt"]
            pt_top = (int(round(b)), y_top)
            pt_bot = (int(round(a * (y_bot - y_top) + b)), y_bot)
            cv2.line(img, pt_top, pt_bot, color, 2)
        cv2.putText(
            img,
            f"{side}: {v_type}",
            (text_x, 50),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            color,
            2,
        )

    # 3. 绘制决策与告警
    if case_info:
        cid = case_info.get("case_id", "")
        cmd = case_info.get("command", "")
        exp = case_info.get("exp", "")
        pred = case_info.get("pred", "")
        stat = case_info.get("status", "")
        stat_color = (0, 255, 0) if stat == "PASS" else (0, 0, 255)

        cv2.putText(
            img,
            f"Case: {cid} Cmd:{cmd}",
            (30, 80),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (255, 255, 255),
            1,
        )
        cv2.putText(
            img,
            f"Exp: {exp} Pred: {pred} [{stat}]",
            (30, 110),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.65,
            stat_color,
            2,
        )

    if res["depart_warning"]:
        cv2.putText(
            img,
            "DEPART WARNING!",
            (380, 200),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.8,
            (0, 0, 255),
            2,
        )

    return img


def evaluate_all(params_override=None, step=1, save_vis=True):
    params = load_params()
    if params_override:
        params.update(params_override)

    model = LaneFPGAModel(params)
    testcases = load_lane_testcases(DEFAULT_TESTCASES)

    os.makedirs(DEFAULT_VIS_DIR, exist_ok=True)

    # 获取涉及的视频
    videos = sorted(list({r["video"] for r in testcases}))
    all_states = {}

    print(f"Running FPGA Golden Model on {len(videos)} videos (step={step})...")
    for vid in videos:
        v_file = os.path.join(DEFAULT_SRC, f"video_20260929_{vid}.mp4")
        if not os.path.isfile(v_file):
            print(f"Warning: video file not found: {v_file}")
            continue
        t0 = time.perf_counter()
        states, fps = run_video_fpga(v_file, model, step=step)
        dt = time.perf_counter() - t0
        all_states[vid] = states
        print(f"[{vid}] {len(states)} frames processed in {dt:.1f}s ({len(states)/dt:.1f} fps)")

    # 评估用例
    edge_trim = 0.3
    pass_ratio = 0.8
    eval_results = []

    # 参考算法 H_pair 的评测状态对照（来自 video_review/ref_runs/H_pair_eval.md）
    # 32 个 LANE 用例在 H_pair 中的实际表现
    ref_hpair_status = {
        "LANE-112507-01": "PASS",
        "LANE-112507-02": "FAIL",
        "LANE-112507-03": "FAIL",
        "LANE-112507-04": "FAIL",
        "LANE-112507-05": "PASS",
        "LANE-112507-06": "PASS",
        "LANE-112507-07": "PASS",
        "LANE-112507-08": "PASS",
        "LANE-112507-09": "PASS",
        "LANE-112507-10": "PASS",
        "LANE-112507-11": "PASS",
        "LANE-112507-12": "FAIL",
        "LANE-112507-13": "FAIL",
        "LANE-112507-14": "FAIL",
        "LANE-112507-15": "PASS",
        "LANE-112507-16": "PASS",
        "LANE-112507-17": "PASS",
        "LANE-112507-18": "PASS",
        "LANE-112507-19": "PASS",
        "LANE-113343-01": "FAIL",
        "LANE-113343-02": "FAIL",
        "LANE-113343-03": "PASS",
        "LANE-113452-01": "PASS",
        "LANE-113539-01": "FAIL",
        "LANE-113539-02": "FAIL",
        "LANE-113539-03": "PASS",
        "LANE-113539-04": "FAIL",
        "LANE-113539-05": "FAIL",
        "LANE-113539-06": "FAIL",
        "LANE-113539-07": "FAIL",
        "LANE-113539-08": "PASS",
        "LANE-113539-09": "FAIL",
    }

    pass_count = 0

    for tc in testcases:
        cid = tc["case_id"]
        vid = tc["video"]
        t0 = float(tc["t_start"])
        t1 = float(tc["t_end"])
        exp = expected_code(tc["expected"])
        side = "left" if tc["lane_or_side"] == "左" else "right"
        force = tc["command"].startswith("强制")

        if t1 - t0 >= 1.2:
            lo, hi = t0 + edge_trim, t1 - edge_trim
        else:
            lo, hi = t0, t1

        v_states = all_states.get(vid, [])
        frames = [r for r in v_states if lo <= r["t"] <= hi]

        if not frames:
            eval_results.append({
                "case_id": cid,
                "video": vid,
                "window": f"[{t0:.2f}, {t1:.2f}]",
                "side": side,
                "command": tc["command"],
                "expected": exp,
                "pred": "NONE",
                "match_ratio": 0.0,
                "status": "NO_FRAMES",
                "ref_status": ref_hpair_status.get(cid, "N/A"),
                "note": tc["note"],
            })
            continue

        preds = [model.decide(fr[side + "_line"], force) for fr in frames]
        n_frames = len(preds)
        correct = sum(1 for p in preds if p == exp)
        ratio = correct / n_frames if n_frames > 0 else 0.0
        status = "PASS" if ratio >= pass_ratio else "FAIL"
        if status == "PASS":
            pass_count += 1
        dom_pred = Counter(preds).most_common(1)[0][0]

        eval_results.append({
            "case_id": cid,
            "video": vid,
            "window": f"[{t0:.2f}, {t1:.2f}]",
            "side": side,
            "command": tc["command"],
            "expected": exp,
            "pred": dom_pred,
            "match_ratio": ratio,
            "status": status,
            "ref_status": ref_hpair_status.get(cid, "N/A"),
            "note": tc["note"],
        })

        # 保存一张代表帧图像 (取窗口中间帧)
        if save_vis and frames:
            mid_idx = len(frames) // 2
            rep_frame = frames[mid_idx]
            case_info = {
                "case_id": cid,
                "command": tc["command"],
                "exp": exp,
                "pred": dom_pred,
                "status": status,
            }
            vis_img = draw_vis_frame(rep_frame, case_info)
            vis_path = os.path.join(DEFAULT_VIS_DIR, f"{cid}.jpg")
            cv2.imwrite(vis_path, vis_img)

    return eval_results, pass_count, len(testcases), params


def generate_report(results, pass_count, total_count, params, out_path):
    L = []
    L.append("# FPGA 定点流式车道线模型评测报告")
    L.append("")
    L.append(f"- 评测时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    L.append(f"- 总用例数：{total_count}，通过数：{pass_count}，通过率：{pass_count/total_count*100:.1f}%")
    L.append("- 对比基线（ref_algo H_pair）：17/32 通过（53.1%）")
    L.append(f"- 最终评估状态：FPGA 定点模型通过数 {pass_count}/32 ({pass_count/total_count*100:.1f}%)")
    L.append("")

    L.append("## 一、全局参数配置")
    L.append("")
    L.append("```json")
    L.append(json.dumps(params, indent=2, ensure_ascii=False))
    L.append("```")
    L.append("")

    L.append("## 二、32 个 LANE 用例逐用例评测明细及与 ref_algo 对比")
    L.append("")
    headers = [
        "用例ID",
        "视频",
        "时间窗(s)",
        "方向",
        "指令",
        "期望",
        "FPGA预测",
        "匹配率",
        "FPGA结果",
        "ref_algo结果",
        "说明",
    ]
    L.append("| " + " | ".join(headers) + " |")
    L.append("| " + " | ".join(["---"] * len(headers)) + " |")

    for r in results:
        row = [
            r["case_id"],
            r["video"],
            r["window"],
            r["side"],
            r["command"],
            r["expected"],
            r["pred"],
            f"{r['match_ratio']*100:.1f}%",
            f"**{r['status']}**" if r["status"] == "PASS" else f"`{r['status']}`",
            r["ref_status"],
            r["note"],
        ]
        L.append("| " + " | ".join(row) + " |")
    L.append("")

    # 差异用例归因分析
    diff_cases = [r for r in results if r["status"] != r["ref_status"]]
    L.append("## 三、FPGA 模型与 ref_algo 结论不同用例分析")
    L.append("")
    if not diff_cases:
        L.append("两者评测结论完全一致。")
    else:
        L.append(f"共有 {len(diff_cases)} 个用例的判定结果发生变化：")
        L.append("")
        for d in diff_cases:
            L.append(
                f"- **{d['case_id']}** ({d['video']}): ref_algo={d['ref_status']} -> FPGA={d['status']} (期望: {d['expected']}, 预测: {d['pred']}, 匹配率: {d['match_ratio']*100:.1f}%, 备注: {d['note']})"
            )
    L.append("")

    # 失败用例归因分析
    fail_cases = [r for r in results if r["status"] != "PASS"]
    L.append("## 四、未通过用例归因分析")
    L.append("")
    if not fail_cases:
        L.append("全部用例均通过测试！")
    else:
        for f in fail_cases:
            L.append(
                f"- **{f['case_id']}** ({f['video']}): 期望 {f['expected']}, 实际主要预测 {f['pred']}, 匹配率 {f['match_ratio']*100:.1f}%, 标注: {f['note']}"
            )
    L.append("")

    # 硬件资源估计
    L.append("## 五、RTL 硬件资源估计（PG2L100H 实现方案）")
    L.append("")
    L.append("按本定点流式模型在 FPGA (Pango PG2L100H) 上的硬件实现结构，资源消耗估算如下：")
    L.append("")
    L.append("### 1. 数据通路与算子分配")
    L.append("| 算法模块 | 操作类型 | 位宽与配置 | 资源类型 | 估计数量 | 说明 |")
    L.append("| --- | --- | --- | --- | --- | --- |")
    L.append("| 窗口 0 预处理 | RGB565 解包 + 移位加法 | 8 位数据流 | 查找表 (LUT) | ~80 LUTs | 无乘法器，加法移位完成 (r+2g+b)>>2 与 (r+g)>>1 |")
    L.append("| 逐行移位缓冲 | 行内局部脊线采样 | 8 位宽，深度 28 | 寄存器 / 移位寄存器 | ~224 FFs | 单行最大 d=14，仅需 2d=28 拍流水线寄存器，**无需 BRAM 行缓冲** |")
    L.append("| 脊线比对与分类 | 减法器与比较器 | 8~10 位比较 | LUT & FF | ~160 LUTs | 计算 R_w, R_y 及白/黄阈值比较 |")
    L.append("| 游程 (Run) 统计 | 计数器与边缘检测 | 10 位计数器 | LUT & FF | ~120 LUTs | 检测连续 Run 起止，求取中心 x=(start+end)>>1 |")
    L.append("| 动态候选与双线 | 绝对值差与窗口比对 | 10 位减法与比较器 | LUT & FF | ~200 LUTs | |x-x_pred|<=W(y) 动态窗口滤波，双线间距比对 |")
    L.append("| 帧累加器 (每侧 6 个) | 累加寄存器 | n(8b), Sy(16b), Syy(24b), Sx(18b), Sxy(26b), Sxx(28b) | 寄存器 (FFs) | ~240 FFs | 双侧共 12 个累加器，逐行实时更新 |")
    L.append("| 帧末最小二乘求解 | 乘法运算 | 28b × 16b / 18b × 16b | 专用 DSP (APM) | 4 个 18×18 DSP | 行末消隐期 (V-Blank) 复用解算分子分母 |")
    L.append("| 帧末定点除法 | 整数除法器 (商与余数) | 36 位被除数 ÷ 24 位除数 | 时序除法器 (Radix-4) | ~400 LUTs, 0 DSP | 利用垂直消隐期 (数百个时钟周期) 进行多拍迭代求解，无需单周期大除法器 |")
    L.append("| EMA 平滑与跟踪表决 | 移位累加与滑动窗口 | 16 位 Q16 / 4 位 Q4 | LUT & 32 位移位寄存器 | ~150 LUTs, 100 FFs | 双侧 EMA 与 32 帧环形队列多数表决 |")
    L.append("")
    L.append("### 2. 总体资源占用概算 (PG2L100H)")
    L.append("- **LUTs (查找表)**: 约 1,800 ~ 2,200 个 (占 PG2L100H 约 2% 逻辑资源)")
    L.append("- **Registers (触发器)**: 约 1,200 ~ 1,500 个 (占总触发器约 1.5%)")
    L.append("- **Block RAM (DRM/BRAM)**: **0 个** (完全不需要整帧缓存或行缓存，纯光栅流式流水线)")
    L.append("- **DSP (APM99)**: 4 个 (占芯片 240 个 DSP 的 1.6%)")
    L.append("- **系统时钟**: 148.5 MHz 时序极为充裕（纯前向简单流水线），易于通过时序收敛。")
    L.append("")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    print(f"Report successfully generated at: {out_path}")


def main():
    parser = argparse.ArgumentParser(description="Evaluate FPGA Lane Detection Golden Model")
    parser.add_argument("--step", type=int, default=1, help="Frame step (1 for all frames, 3 for 10fps)")
    parser.add_argument("--out-md", default=DEFAULT_OUT_MD, help="Output markdown report path")
    parser.add_argument("--no-vis", action="store_true", help="Disable saving visualization frames")
    args = parser.parse_args()

    results, pass_count, total_count, params = evaluate_all(
        params_override=None, step=args.step, save_vis=not args.no_vis
    )

    generate_report(results, pass_count, total_count, params, args.out_md)
    print(f"Summary: {pass_count}/{total_count} passed ({pass_count/total_count*100:.1f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
