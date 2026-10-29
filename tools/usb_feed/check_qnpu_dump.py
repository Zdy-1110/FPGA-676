#!/usr/bin/env python3
"""Validate board-side npu detection results against RKNN Toolkit2 simulator.

Compares 12 raw RGB dumps (960x320x3 RGB888) and corresponding board detection
results (.txt) from log/qnpu/qnpu_dump/ against PC INT8 RKNN simulator outputs.
Reuses functions from tools/npu_det/compare_board_sim.py.
"""

import glob
import json
import os
import sys
import time

import cv2
import numpy as np

# Set up module search paths to reuse existing project utilities
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
for _d in (
    os.path.join(_ROOT, "tools", "npu_det"),
    os.path.join(_ROOT, "tools", "npu_convert"),
    os.path.join(_ROOT, "tools", "npu_train"),
):
    if _d not in sys.path:
        sys.path.insert(0, _d)

import compare_board_sim
import convert_rknn
import rknn_postprocess

# Authorized runtime monkeypatch for B5 model
compare_board_sim.MODELS["b5"] = os.path.join(_ROOT, "models", "npu", "b5_v6n_band.onnx")

ONNX_PATH = os.path.join(_ROOT, "models", "npu", "b5_v6n_band.onnx")
CALIB_PATH = os.path.join(_ROOT, "models", "npu", "calib", "band_960x320", "dataset.txt")
DUMP_DIR = os.path.join(_ROOT, "log", "qnpu", "qnpu_dump")
VIS_DIR = os.path.join(_ROOT, "log", "qnpu", "vis")
REPORT_PATH = os.path.join(_ROOT, "log", "qnpu", "check_report.md")

NET_W, NET_H = 960, 320
CONF_THRES = 0.25
IOU_THRES = 0.6
MAX_DET = 300
NMS_MODE = "pr_split"
MATCH_IOU = 0.5


def log(msg):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def read_board_txt(path):
    """Read board detection txt: cls score x0 y0 x1 y1."""
    dets = []
    if not os.path.isfile(path):
        return dets
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) < 6:
                continue
            cls = int(parts[0])
            score = float(parts[1])
            box = [float(parts[2]), float(parts[3]), float(parts[4]), float(parts[5])]
            dets.append({"cls": cls, "score": score, "box": box})
    return dets


def infer_band(rknn, meta, rgb):
    """Run simulator on 960x320x3 raw RGB and return band detections."""
    raw = rknn.inference(inputs=[np.ascontiguousarray(rgb[None])], data_format="nhwc")
    outs = convert_rknn.coerce_outputs(raw, meta["outputs"])
    boxes, scores = rknn_postprocess.dfl_decode(outs, meta["strides"], meta["reg_max"])
    b, s, c = rknn_postprocess.nms(
        boxes,
        scores,
        conf_thres=CONF_THRES,
        iou_thres=IOU_THRES,
        max_det=MAX_DET,
        mode=NMS_MODE,
    )
    dets = []
    for bi, si, ci in zip(b, s, c):
        dets.append({"cls": int(ci), "score": float(si), "box": bi.tolist()})
    return dets


def draw_vis(rgb, board_dets, sim_dets, class_names, out_path):
    """Convert RGB to PNG and draw board (and sim) detections."""
    # Convert RGB to BGR for OpenCV
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)

    # Palette
    color_board = (0, 255, 0)     # Green for board
    color_sim = (255, 128, 0)     # Cyan/Blue for simulator

    # Draw simulator boxes first with thin line
    for d in sim_dets:
        box = [int(round(x)) for x in d["box"]]
        c = d["cls"]
        s = d["score"]
        name = class_names[c] if c < len(class_names) else str(c)
        cv2.rectangle(bgr, (box[0], box[1]), (box[2], box[3]), color_sim, 1)

    # Draw board boxes with prominent label
    for d in board_dets:
        box = [int(round(x)) for x in d["box"]]
        c = d["cls"]
        s = d["score"]
        name = class_names[c] if c < len(class_names) else str(c)
        cv2.rectangle(bgr, (box[0], box[1]), (box[2], box[3]), color_board, 2)
        label = f"{name} {s:.2f}"
        (tw, th), baseline = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
        ty = max(box[1] - 4, th + 2)
        cv2.rectangle(
            bgr,
            (box[0], ty - th - 2),
            (box[0] + tw + 2, ty + baseline - 2),
            (0, 160, 0),
            -1,
        )
        cv2.putText(
            bgr,
            label,
            (box[0] + 1, ty - 1),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.5,
            (255, 255, 255),
            1,
            cv2.LINE_AA,
        )

    # Add legend at top left
    cv2.putText(
        bgr,
        "Board (Green) | Sim (Cyan)",
        (10, 20),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.6,
        (0, 0, 0),
        2,
        cv2.LINE_AA,
    )
    cv2.putText(
        bgr,
        "Board (Green) | Sim (Cyan)",
        (10, 20),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.6,
        (255, 255, 255),
        1,
        cv2.LINE_AA,
    )

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    cv2.imwrite(out_path, bgr)


def main():
    log("========== check_qnpu_dump: Board vs RKNN Simulator ==========")
    log("ONNX path      : %s" % ONNX_PATH)
    log("Calib path     : %s" % CALIB_PATH)
    log("Dump dir       : %s" % DUMP_DIR)

    meta = convert_rknn.load_meta(ONNX_PATH)
    class_names = meta.get("names", [])
    log("Class names (%d): %s" % (len(class_names), class_names))

    # Discover the 12 .rgb files in log/qnpu/qnpu_dump/
    rgb_files = sorted(glob.glob(os.path.join(DUMP_DIR, "ch*.rgb")))
    if not rgb_files:
        log("ERROR: No .rgb files found in %s" % DUMP_DIR)
        return 1
    log("Found %d rgb dumps to evaluate." % len(rgb_files))

    out_calib_dir = os.path.join(_ROOT, "log", "qnpu")
    os.makedirs(out_calib_dir, exist_ok=True)
    os.makedirs(VIS_DIR, exist_ok=True)

    log("Building INT8 RKNN simulator...")
    rknn, build_info = compare_board_sim.build_simulator(
        ONNX_PATH, CALIB_PATH, "rk3568", out_calib_dir, "b5"
    )
    log("Simulator ready (build took %.2fs)" % build_info["build_seconds"])

    file_results = []
    all_matches = []
    all_unmatched_board = []
    all_unmatched_sim = []

    try:
        # Warmup simulator
        first_rgb = np.fromfile(rgb_files[0], dtype=np.uint8).reshape(NET_H, NET_W, 3)
        infer_band(rknn, meta, first_rgb)

        for rgb_path in rgb_files:
            fname = os.path.basename(rgb_path)
            stem = os.path.splitext(fname)[0]
            txt_path = os.path.join(DUMP_DIR, stem + ".txt")

            rgb = np.fromfile(rgb_path, dtype=np.uint8).reshape(NET_H, NET_W, 3)
            board_dets = read_board_txt(txt_path)
            sim_dets = infer_band(rknn, meta, rgb)

            matches, un_board, un_sim = compare_board_sim.match_frame(
                board_dets, sim_dets, iou_thres=MATCH_IOU
            )

            mean_iou = (
                float(np.mean([m[2] for m in matches])) if matches else None
            )
            mean_ds = (
                float(np.mean([abs(m[0]["score"] - m[1]["score"]) for m in matches]))
                if matches
                else None
            )

            un_b_ge05 = [d for d in un_board if d["score"] >= 0.5]
            un_s_ge05 = [s for s in un_sim if s["score"] >= 0.5]

            # Save visualization
            vis_png = os.path.join(VIS_DIR, stem + ".png")
            draw_vis(rgb, board_dets, sim_dets, class_names, vis_png)

            res = {
                "file": stem,
                "board_count": len(board_dets),
                "sim_count": len(sim_dets),
                "matched_count": len(matches),
                "mean_iou": mean_iou,
                "mean_ds": mean_ds,
                "unmatched_board": un_board,
                "unmatched_sim": un_sim,
                "un_b_ge05": un_b_ge05,
                "un_s_ge05": un_s_ge05,
                "matches": matches,
            }
            file_results.append(res)
            all_matches.extend(matches)
            all_unmatched_board.extend([(stem, d) for d in un_board])
            all_unmatched_sim.extend([(stem, s) for s in un_sim])

            log(
                "%-10s | Board: %2d | Sim: %2d | Match: %2d | MeanIoU: %s | Mean|ds|: %s | "
                "Unmatch(>=0.5) B:%d S:%d"
                % (
                    stem,
                    len(board_dets),
                    len(sim_dets),
                    len(matches),
                    ("%.4f" % mean_iou) if mean_iou is not None else " N/A",
                    ("%.5f" % mean_ds) if mean_ds is not None else "  N/A",
                    len(un_b_ge05),
                    len(un_s_ge05),
                )
            )

    finally:
        try:
            rknn.release()
        except Exception:
            pass

    # Overall evaluation
    total_board = sum(r["board_count"] for r in file_results)
    total_sim = sum(r["sim_count"] for r in file_results)
    total_matched = sum(r["matched_count"] for r in file_results)
    overall_mean_iou = (
        float(np.mean([m[2] for m in all_matches])) if all_matches else 0.0
    )
    overall_mean_ds = (
        float(np.mean([abs(m[0]["score"] - m[1]["score"]) for m in all_matches]))
        if all_matches
        else 0.0
    )
    total_un_b_ge05 = sum(len(r["un_b_ge05"]) for r in file_results)
    total_un_s_ge05 = sum(len(r["un_s_ge05"]) for r in file_results)

    pass_ge05 = (total_un_b_ge05 == 0) and (total_un_s_ge05 == 0)
    pass_iou = overall_mean_iou >= 0.90
    verdict = "PASS" if (pass_ge05 and pass_iou) else "FAIL"

    log("---------------- Summary ----------------")
    log("Total Board boxes      : %d" % total_board)
    log("Total Sim boxes        : %d" % total_sim)
    log("Total Matched boxes    : %d" % total_matched)
    log("Overall Mean IoU       : %.4f (threshold >= 0.90)" % overall_mean_iou)
    log("Overall Mean |dscore|  : %.5f" % overall_mean_ds)
    log(
        "Unmatched (score>=0.5) : Board=%d, Sim=%d (threshold == 0)"
        % (total_un_b_ge05, total_un_s_ge05)
    )
    log("VERDICT                : %s" % verdict)

    # Inconsistent boxes list (score >= 0.5 unmatched, or IoU < 0.9 matches)
    inconsistent_boxes = []
    for stem, d in all_unmatched_board:
        if d["score"] >= 0.5:
            c = d["cls"]
            name = class_names[c] if c < len(class_names) else str(c)
            inconsistent_boxes.append(
                f"- [Only Board >=0.5] File `{stem}`: cls={d['cls']}({name}), score={d['score']:.4f}, box={d['box']}"
            )
    for stem, s in all_unmatched_sim:
        if s["score"] >= 0.5:
            c = s["cls"]
            name = class_names[c] if c < len(class_names) else str(c)
            inconsistent_boxes.append(
                f"- [Only Sim >=0.5] File `{stem}`: cls={s['cls']}({name}), score={s['score']:.4f}, box={s['box']}"
            )

    # Write check_report.md
    with open(REPORT_PATH, "w", encoding="utf-8") as rf:
        rf.write("# RK3568 板端 NPU 检测 vs PC RKNN 模拟器对拍报告\n\n")
        rf.write(f"- **日期**: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        rf.write(f"- **模型**: B5 (`models/npu/b5_v6n_band.onnx` / `b5_v6n_band.rknn`)\n")
        rf.write(f"- **输入规格**: 960×320×3 RGB888 (raw RGB dump)\n")
        rf.write(f"- **量化平台**: `rk3568`, INT8 asymmetric, channel\n")
        rf.write(f"- **后处理参数**: conf >= {CONF_THRES}, NMS IoU = {IOU_THRES}, mode = `{NMS_MODE}`, max_det = {MAX_DET}\n")
        rf.write(f"- **匹配阈值**: IoU >= {MATCH_IOU} (同类别贪心匹配)\n")
        rf.write(f"- **对拍判定标准**: score >= 0.5 框全部匹配 且 匹配框平均 IoU >= 0.90\n")
        rf.write(f"- **最终结论**: **{verdict}**\n\n")

        rf.write("## 1. 12 组输入逐文件对比统计表\n\n")
        rf.write(
            "| 文件名 | 板端框数 | 模拟器框数 | 匹配数 | 匹配框平均 IoU | score 平均绝对差 | 板端未匹配(≥0.5) | 模拟器未匹配(≥0.5) |\n"
        )
        rf.write(
            "| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |\n"
        )
        for r in file_results:
            miou_str = f"{r['mean_iou']:.4f}" if r["mean_iou"] is not None else "-"
            mds_str = f"{r['mean_ds']:.5f}" if r["mean_ds"] is not None else "-"
            rf.write(
                f"| `{r['file']}` | {r['board_count']} | {r['sim_count']} | {r['matched_count']} | "
                f"{miou_str} | {mds_str} | {len(r['un_b_ge05'])} | {len(r['un_s_ge05'])} |\n"
            )

        rf.write("\n## 2. 总体汇总\n\n")
        rf.write(f"- **总板端框数**: {total_board}\n")
        rf.write(f"- **总模拟器框数**: {total_sim}\n")
        rf.write(f"- **总匹配框数**: {total_matched}\n")
        rf.write(f"- **全量匹配框平均 IoU**: `{overall_mean_iou:.4f}` (阈值 >= 0.90: **{'PASS' if pass_iou else 'FAIL'}**)\n")
        rf.write(f"- **全量匹配框 score 平均绝对差**: `{overall_mean_ds:.5f}`\n")
        rf.write(
            f"- **score >= 0.5 未匹配框数**: 板端 `{total_un_b_ge05}`, 模拟器 `{total_un_s_ge05}` "
            f"(阈值 == 0: **{'PASS' if pass_ge05 else 'FAIL'}**)\n\n"
        )

        rf.write("## 3. 不一致框清单 (score >= 0.5)\n\n")
        if inconsistent_boxes:
            for item in inconsistent_boxes:
                rf.write(item + "\n")
        else:
            rf.write("无。全部 score >= 0.5 目标框在板端与 PC 模拟器间 100% 成功匹配。\n")

        rf.write("\n## 4. 低置信度框差异分析 (0.25 <= score < 0.5)\n\n")
        low_diff_found = False
        for r in file_results:
            low_b = [d for d in r["unmatched_board"] if d["score"] < 0.5]
            low_s = [s for s in r["unmatched_sim"] if s["score"] < 0.5]
            if low_b or low_s:
                low_diff_found = True
                rf.write(f"### `{r['file']}`\n")
                for d in low_b:
                    c = d["cls"]
                    name = class_names[c] if c < len(class_names) else str(c)
                    rf.write(f"- 板端独有: cls={c}({name}), score={d['score']:.4f}, box={[round(x, 1) for x in d['box']]}\n")
                for s in low_s:
                    c = s["cls"]
                    name = class_names[c] if c < len(class_names) else str(c)
                    rf.write(f"- 模拟器独有: cls={c}({name}), score={s['score']:.4f}, box={[round(x, 1) for x in s['box']]}\n")
        if not low_diff_found:
            rf.write("无。全部低置信度框亦全部匹配。\n")

        rf.write("\n## 5. 可视化产物\n\n")
        rf.write(f"可视化图像保存在 `log/qnpu/vis/`，每个 .rgb 转换为同名 .png：\n\n")
        for r in file_results:
            rf.write(f"- `log/qnpu/vis/{r['file']}.png`\n")

    log("Report written to %s" % REPORT_PATH)
    log("Visualization saved in %s" % VIS_DIR)
    return 0 if verdict == "PASS" else 2


if __name__ == "__main__":
    sys.exit(main())
