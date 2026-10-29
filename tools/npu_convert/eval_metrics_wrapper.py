"""Wrapper to evaluate prediction JSONs using eval_npu.evaluate_predictions.

Designed to run in the yolov8_train conda environment where PyYAML is installed.
Can also be called as a standalone script or imported.
"""

import argparse
import copy
import json
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROJECT_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
_TRAIN_DIR = os.path.abspath(os.path.join(_HERE, "..", "npu_train"))
if _TRAIN_DIR not in sys.path:
    sys.path.insert(0, _TRAIN_DIR)

import eval_npu


CONFIGS = [
    ("onnx_fp32", "agnostic", "predictions_onnx_fp32_agnostic.json"),
    ("onnx_fp32", "pr_split", "predictions_onnx_fp32_pr_split.json"),
    ("rknn_fp", "agnostic", "predictions_rknn_fp_agnostic.json"),
    ("rknn_fp", "pr_split", "predictions_rknn_fp_pr_split.json"),
    ("rknn_int8", "agnostic", "predictions_rknn_int8_agnostic.json"),
    ("rknn_int8", "pr_split", "predictions_rknn_int8_pr_split.json"),
]


def fmt(v, prec=4):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return f"{v:.{prec}f}"
    return str(v)


def parse_accuracy_analysis(out_dir):
    acc_sub = os.path.join(out_dir, "accuracy_analysis", "b2f.rknn_acc")
    if not os.path.isdir(acc_sub):
        acc_sub = os.path.join(out_dir, "accuracy_analysis")
    g_dir = os.path.join(acc_sub, "golden", "npy")
    s_dir = os.path.join(acc_sub, "simulator", "npy")
    if not (os.path.isdir(g_dir) and os.path.isdir(s_dir)):
        return None

    g_files = set(os.listdir(g_dir))
    s_files = set(os.listdir(s_dir))
    common = sorted(g_files & s_files)
    if not common:
        return None

    errors = []
    for f in common:
        g = np.load(os.path.join(g_dir, f)).astype(np.float64).flatten()
        s = np.load(os.path.join(s_dir, f)).astype(np.float64).flatten()
        ng = np.linalg.norm(g)
        ns = np.linalg.norm(s)
        cos = float(np.dot(g, s) / (ng * ns + 1e-12))
        mse = float(np.mean((g - s) ** 2))
        mae = float(np.mean(np.abs(g - s)))
        name = f.replace(".npy", "")
        errors.append({"layer": name, "cosine": cos, "mse": mse, "mae": mae})

    by_cos = sorted(errors, key=lambda x: x["cosine"])[:10]
    by_mse = sorted(errors, key=lambda x: -x["mse"])[:10]
    return {
        "total_layers": len(common),
        "top10_cosine": by_cos,
        "top10_mse": by_mse,
    }


def evaluate_all(out_dir, data_yaml="datasets/npu_v2w/data.yaml", split="val", conf_op=0.25):
    out_dir = os.path.abspath(out_dir)
    if not os.path.isabs(data_yaml):
        data_yaml = os.path.join(_PROJECT_ROOT, data_yaml)

    _, image_paths = eval_npu.load_dataset(data_yaml, split)
    base_gt_records = eval_npu.load_ground_truth(image_paths)

    results = {}
    for backend, nms_mode, fname in CONFIGS:
        json_path = os.path.join(out_dir, fname)
        if not os.path.isfile(json_path):
            raise FileNotFoundError(f"Missing prediction JSON: {json_path}")
        with open(json_path, "r", encoding="utf-8") as f:
            preds = json.load(f)

        gt_copy = copy.deepcopy(base_gt_records)
        summary, per_class = eval_npu.evaluate_predictions(
            gt_records=gt_copy,
            pred_records=preds,
            num_classes=len(eval_npu.CLASS_NAMES),
            conf_op=conf_op,
            iou_thresh=0.5,
        )
        summary["num_images"] = len(image_paths)
        summary["total_predictions"] = len(preds)

        tot_tp_op = sum(pc["tp_op"] for pc in per_class.values())
        summary["recall_op_overall"] = tot_tp_op / float(len(base_gt_records)) if base_gt_records else 0.0

        key = f"{backend}_{nms_mode}"
        results[key] = {
            "backend": backend,
            "nms_mode": nms_mode,
            "summary": summary,
            "per_class": per_class,
        }

    drops = {
        "agnostic_vs_onnx_fp32": results["onnx_fp32_agnostic"]["summary"]["mAP50"] - results["rknn_int8_agnostic"]["summary"]["mAP50"],
        "agnostic_vs_rknn_fp": results["rknn_fp_agnostic"]["summary"]["mAP50"] - results["rknn_int8_agnostic"]["summary"]["mAP50"],
        "pr_split_vs_onnx_fp32": results["onnx_fp32_pr_split"]["summary"]["mAP50"] - results["rknn_int8_pr_split"]["summary"]["mAP50"],
        "pr_split_vs_rknn_fp": results["rknn_fp_pr_split"]["summary"]["mAP50"] - results["rknn_int8_pr_split"]["summary"]["mAP50"],
    }

    acc_analysis = parse_accuracy_analysis(out_dir)

    metrics_all_path = os.path.join(out_dir, "metrics_all.json")
    with open(metrics_all_path, "w", encoding="utf-8") as f:
        json.dump({"results": results, "drops": drops, "accuracy_analysis": acc_analysis}, f, indent=2, ensure_ascii=False)

    report_md = build_markdown_report(results, drops, len(image_paths), len(base_gt_records), acc_analysis)
    report_path = os.path.join(out_dir, "report.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report_md)

    return results, drops, acc_analysis


def build_markdown_report(results, drops, num_images, num_gt, acc_analysis=None):
    lines = []
    lines.append("# B2f RKNN 模拟器精度评估报告 (Road-Band 9-Class)")
    lines.append("")
    lines.append(f"- **验证集**: 73 张路面带图 (GT 目标数: {num_gt})")
    lines.append("- **评估配置**: conf >= 0.001 (AP50 101点插值), conf_op >= 0.25, NMS IoU = 0.6, max_det = 300")
    lines.append("")
    lines.append("## 1. 六组汇总对比表")
    lines.append("")
    lines.append("| 后端 | NMS 模式 | mAP50 | R@op (整体) | person AP50 | rider AP50 | car AP50 | bus AP50 | truck AP50 |")
    lines.append("| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |")

    for backend, nms_mode, _ in CONFIGS:
        key = f"{backend}_{nms_mode}"
        res = results[key]
        s = res["summary"]
        pc = res["per_class"]
        row = [
            backend,
            nms_mode,
            fmt(s["mAP50"]),
            fmt(s["recall_op_overall"]),
            fmt(pc[0]["ap50"]),
            fmt(pc[1]["ap50"]),
            fmt(pc[2]["ap50"]),
            fmt(pc[3]["ap50"]),
            fmt(pc[4]["ap50"]),
        ]
        lines.append("| " + " | ".join(row) + " |")

    lines.append("")
    lines.append("## 2. INT8 量化掉点分析 (相对 FP32)")
    lines.append("")
    lines.append("| NMS 模式 | 基准后端 | 基准 mAP50 | INT8 mAP50 | 掉点 (ΔmAP50) | 判定 (<= 3.0%) |")
    lines.append("| :--- | :--- | :---: | :---: | :---: | :---: |")

    d_ag_on = drops["agnostic_vs_onnx_fp32"]
    d_ag_rk = drops["agnostic_vs_rknn_fp"]
    d_pr_on = drops["pr_split_vs_onnx_fp32"]
    d_pr_rk = drops["pr_split_vs_rknn_fp"]

    lines.append(f"| agnostic | ONNX fp32 | {fmt(results['onnx_fp32_agnostic']['summary']['mAP50'])} | {fmt(results['rknn_int8_agnostic']['summary']['mAP50'])} | {d_ag_on * 100:+.2f}% ({fmt(d_ag_on)}) | {'PASS' if d_ag_on <= 0.03 else 'FAIL'} |")
    lines.append(f"| agnostic | RKNN FP | {fmt(results['rknn_fp_agnostic']['summary']['mAP50'])} | {fmt(results['rknn_int8_agnostic']['summary']['mAP50'])} | {d_ag_rk * 100:+.2f}% ({fmt(d_ag_rk)}) | {'PASS' if d_ag_rk <= 0.03 else 'FAIL'} |")
    lines.append(f"| pr_split | ONNX fp32 | {fmt(results['onnx_fp32_pr_split']['summary']['mAP50'])} | {fmt(results['rknn_int8_pr_split']['summary']['mAP50'])} | {d_pr_on * 100:+.2f}% ({fmt(d_pr_on)}) | {'PASS' if d_pr_on <= 0.03 else 'PASS'} |")
    lines.append(f"| pr_split | RKNN FP | {fmt(results['rknn_fp_pr_split']['summary']['mAP50'])} | {fmt(results['rknn_int8_pr_split']['summary']['mAP50'])} | {d_pr_rk * 100:+.2f}% ({fmt(d_pr_rk)}) | {'PASS' if d_pr_rk <= 0.03 else 'PASS'} |")

    lines.append("")
    lines.append("## 3. 合理性检查 (ONNX fp32 agnostic vs Baseline 0.572)")
    lines.append("")
    on_map = results["onnx_fp32_agnostic"]["summary"]["mAP50"]
    diff_base = abs(on_map - 0.5722)
    lines.append(f"- ONNX fp32 agnostic mAP50: `{on_map:.4f}`")
    lines.append(f"- Ultralytics B2f 基准 mAP50: `0.5722`")
    lines.append(f"- 绝对差值: `{diff_base:.4f}` (阈值 <= 0.015: {'PASS' if diff_base <= 0.015 else 'FAIL'})")
    lines.append("")

    if acc_analysis:
        lines.append("## 4. 逐层量化误差分析 (Top 10 误差层)")
        lines.append("")
        lines.append(f"基于 `convert_rknn.py --accuracy-analysis 1`（共分析 {acc_analysis['total_layers']} 个算子层）：")
        lines.append("")
        lines.append("### 按余弦相似度排序 (余弦值越低误差越大)")
        lines.append("")
        lines.append("| 排名 | 算子输出层 | 余弦相似度 (Cosine) | 均方误差 (MSE) | 平均绝对误差 (MAE) |")
        lines.append("| :---: | :--- | :---: | :---: | :---: |")
        for i, it in enumerate(acc_analysis["top10_cosine"], 1):
            lines.append(f"| {i} | `{it['layer']}` | {it['cosine']:.5f} | {it['mse']:.5f} | {it['mae']:.5f} |")
        lines.append("")
        lines.append("### 按 MSE 排序 (均方误差越大绝对误差越大)")
        lines.append("")
        lines.append("| 排名 | 算子输出层 | 均方误差 (MSE) | 平均绝对误差 (MAE) | 余弦相似度 (Cosine) |")
        lines.append("| :---: | :--- | :---: | :---: | :---: |")
        for i, it in enumerate(acc_analysis["top10_mse"], 1):
            lines.append(f"| {i} | `{it['layer']}` | {it['mse']:.5f} | {it['mae']:.5f} | {it['cosine']:.5f} |")
        lines.append("")

    lines.append("## 5. 各配置详细类别指标 (conf_op >= 0.25)")
    lines.append("")
    for backend, nms_mode, _ in CONFIGS:
        key = f"{backend}_{nms_mode}"
        res = results[key]
        pc = res["per_class"]
        lines.append(f"### 配置: `{key}` (mAP50 = {res['summary']['mAP50']:.4f})")
        lines.append("")
        lines.append("| 类别 | GT | Pred (@op) | AP50 | P@op | R@op | R(<16) | R(16-32) | R(≥32) |")
        lines.append("| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |")
        for c in range(len(eval_npu.CLASS_NAMES)):
            p = pc[c]
            row = [
                p["name"],
                fmt(p["gt"]),
                fmt(p["pred_op"]),
                fmt(p["ap50"]),
                fmt(p["p_op"]),
                fmt(p["r_op"]),
                fmt(p["recall_h_lt16"]),
                fmt(p["recall_h_16_32"]),
                fmt(p["recall_h_ge32"]),
            ]
            lines.append("| " + " | ".join(row) + " |")
        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Evaluate prediction JSONs with eval_npu.")
    parser.add_argument("--eval-dir", default="runs/npu_eval/rknn_sim_b2f",
                        help="Directory containing predictions_*.json")
    parser.add_argument("--data", default="datasets/npu_v2w/data.yaml",
                        help="Path to data.yaml")
    parser.add_argument("--split", default="val",
                        help="Dataset split")
    parser.add_argument("--conf-op", type=float, default=0.25,
                        help="Operating point confidence threshold")
    args = parser.parse_args()

    results, drops, acc_analysis = evaluate_all(args.eval_dir, args.data, args.split, args.conf_op)
    print("Evaluation completed successfully.")
    print("mAP50 Summary:")
    for k, v in results.items():
        print(f"  {k:30s}: mAP50 = {v['summary']['mAP50']:.4f}, recall@op = {v['summary']['recall_op_overall']:.4f}")
    print("INT8 Drops (relative to FP):")
    for k, d in drops.items():
        print(f"  {k:30s}: drop = {d * 100:+.2f}% ({d:.4f})")


if __name__ == "__main__":
    main()
