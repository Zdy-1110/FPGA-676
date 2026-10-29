#!/usr/bin/env python3
"""Unified evaluation script for Road-Band 9-class NPU models.

Supports three prediction modes:
  - model: trained 9-class YOLOv8 model
  - coco: COCO-pretrained YOLOv8 with class mapping (B0 baseline)
  - oracle: ground-truth itself (for pipeline verification)
"""

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

# Add current directory to sys.path so npu_common can be imported cleanly
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from npu_common import CLASS_NAMES, coco_to_project, read_yolo_txt


def check_env():
    """Environment guard to ensure isolated and offline Ultralytics execution."""
    cfg_dir = os.environ.get("YOLO_CONFIG_DIR", "").rstrip("/\\")
    autoinstall = os.environ.get("YOLO_AUTOINSTALL", "")
    offline = os.environ.get("YOLO_OFFLINE", "")

    cond_cfg = cfg_dir.endswith(".yolo_cfg_wsl")
    cond_auto = autoinstall.lower() in ("false", "0", "no")
    cond_off = offline.lower() in ("true", "1", "yes")

    if not (cond_cfg and cond_auto and cond_off):
        sys.stderr.write(
            "ERROR: Environment guard failed (exit code 2).\n"
            f"  YOLO_CONFIG_DIR must end with '.yolo_cfg_wsl' (got: '{cfg_dir}')\n"
            f"  YOLO_AUTOINSTALL must be False (got: '{autoinstall}')\n"
            f"  YOLO_OFFLINE must be True (got: '{offline}')\n"
        )
        sys.exit(2)


def box_iou(b1, b2):
    """Compute IoU between two bounding boxes [x1, y1, x2, y2]."""
    ix1 = max(b1[0], b2[0])
    iy1 = max(b1[1], b2[1])
    ix2 = min(b1[2], b2[2])
    iy2 = min(b1[3], b2[3])

    iw = max(0.0, ix2 - ix1)
    ih = max(0.0, iy2 - iy1)
    inter = iw * ih
    if inter <= 0.0:
        return 0.0

    area1 = max(0.0, b1[2] - b1[0]) * max(0.0, b1[3] - b1[1])
    area2 = max(0.0, b2[2] - b2[0]) * max(0.0, b2[3] - b2[1])
    union = area1 + area2 - inter
    if union <= 0.0:
        return 0.0
    return inter / union


def compute_ap50(tp, fp, n_gt):
    """Compute AP50 using COCO 101-point interpolation."""
    if n_gt == 0:
        return None
    if len(tp) == 0:
        return 0.0

    tp_cum = np.cumsum(tp)
    fp_cum = np.cumsum(fp)
    recalls = tp_cum / float(n_gt)
    precisions = tp_cum / (tp_cum + fp_cum)

    recall_thresholds = np.linspace(0.0, 1.0, 101)
    prec_interp = np.zeros(101, dtype=np.float64)
    for i, r in enumerate(recall_thresholds):
        mask = recalls >= r
        if np.any(mask):
            prec_interp[i] = np.max(precisions[mask])
        else:
            prec_interp[i] = 0.0

    return float(np.mean(prec_interp))


def evaluate_predictions(gt_records, pred_records, num_classes=9, conf_op=0.25, iou_thresh=0.5):
    """Greedy matching and metric computation shared by all modes.

    Args:
        gt_records: list of dicts with:
            {'img_idx': int, 'cls': int, 'box': (x1, y1, x2, y2), 'h': float, 'bucket': str}
        pred_records: list of dicts with:
            {'img_idx': int, 'cls': int, 'conf': float, 'box': (x1, y1, x2, y2)}
        num_classes: int
        conf_op: float, operating point confidence threshold
        iou_thresh: float, IoU threshold for matching (default 0.5)

    Returns:
        tuple (summary_dict, per_class_dict)
    """
    gts_by_class_img = {}
    for g in gt_records:
        g["matched"] = False
        g["matched_at_op"] = False
        key = (g["cls"], g["img_idx"])
        if key not in gts_by_class_img:
            gts_by_class_img[key] = []
        gts_by_class_img[key].append(g)

    preds_by_class = {c: [] for c in range(num_classes)}
    for p in pred_records:
        if 0 <= p["cls"] < num_classes:
            preds_by_class[p["cls"]].append(p)

    per_class = {}

    for c in range(num_classes):
        class_gts = [g for g in gt_records if g["cls"] == c]
        n_gt = len(class_gts)
        class_preds = preds_by_class[c]
        class_preds.sort(key=lambda d: d["conf"], reverse=True)

        n_pred_all = len(class_preds)
        n_pred_op = sum(1 for p in class_preds if p["conf"] >= conf_op)

        tp = []
        fp = []

        for p in class_preds:
            candidates = gts_by_class_img.get((c, p["img_idx"]), [])
            best_iou = -1.0
            best_gt = None
            for g in candidates:
                iou = box_iou(p["box"], g["box"])
                if iou > best_iou:
                    best_iou = iou
                    best_gt = g

            if best_iou >= iou_thresh:
                if not best_gt["matched"]:
                    best_gt["matched"] = True
                    tp.append(1)
                    fp.append(0)
                    if p["conf"] >= conf_op:
                        best_gt["matched_at_op"] = True
                else:
                    tp.append(0)
                    fp.append(1)
            else:
                tp.append(0)
                fp.append(1)

        ap50 = compute_ap50(tp, fp, n_gt)

        tp_op = sum(tp[:n_pred_op])
        fp_op = sum(fp[:n_pred_op])

        if n_gt > 0:
            r_op = float(tp_op) / float(n_gt)
            p_op = float(tp_op) / float(n_pred_op) if n_pred_op > 0 else 0.0
        else:
            r_op = None
            p_op = (float(tp_op) / float(n_pred_op)) if n_pred_op > 0 else None

        gts_lt16 = [g for g in class_gts if g["bucket"] == "lt16"]
        gts_16_32 = [g for g in class_gts if g["bucket"] == "16_32"]
        gts_ge32 = [g for g in class_gts if g["bucket"] == "ge32"]

        recalled_lt16 = sum(1 for g in gts_lt16 if g["matched_at_op"])
        recalled_16_32 = sum(1 for g in gts_16_32 if g["matched_at_op"])
        recalled_ge32 = sum(1 for g in gts_ge32 if g["matched_at_op"])

        r_lt16 = (float(recalled_lt16) / len(gts_lt16)) if len(gts_lt16) > 0 else None
        r_16_32 = (float(recalled_16_32) / len(gts_16_32)) if len(gts_16_32) > 0 else None
        r_ge32 = (float(recalled_ge32) / len(gts_ge32)) if len(gts_ge32) > 0 else None

        per_class[c] = {
            "class_id": c,
            "name": CLASS_NAMES[c] if c < len(CLASS_NAMES) else f"class_{c}",
            "gt": n_gt,
            "pred_op": n_pred_op,
            "pred_all": n_pred_all,
            "tp_op": tp_op,
            "fp_op": fp_op,
            "tp_total": sum(tp),
            "fp_total": sum(fp),
            "ap50": ap50,
            "p_op": p_op,
            "r_op": r_op,
            "recall_h_lt16": r_lt16,
            "recall_h_16_32": r_16_32,
            "recall_h_ge32": r_ge32,
            "gt_h_lt16": len(gts_lt16),
            "gt_h_16_32": len(gts_16_32),
            "gt_h_ge32": len(gts_ge32),
            "recalled_h_lt16": recalled_lt16,
            "recalled_h_16_32": recalled_16_32,
            "recalled_h_ge32": recalled_ge32,
        }

    classes_with_gt = [c for c in range(num_classes) if per_class[c]["gt"] > 0]
    mAP50 = float(np.mean([per_class[c]["ap50"] for c in classes_with_gt])) if classes_with_gt else None

    all_lt16 = [g for g in gt_records if g["bucket"] == "lt16"]
    all_16_32 = [g for g in gt_records if g["bucket"] == "16_32"]
    all_ge32 = [g for g in gt_records if g["bucket"] == "ge32"]

    all_recalled_lt16 = sum(1 for g in all_lt16 if g["matched_at_op"])
    all_recalled_16_32 = sum(1 for g in all_16_32 if g["matched_at_op"])
    all_recalled_ge32 = sum(1 for g in all_ge32 if g["matched_at_op"])

    overall_r_lt16 = (float(all_recalled_lt16) / len(all_lt16)) if len(all_lt16) > 0 else None
    overall_r_16_32 = (float(all_recalled_16_32) / len(all_16_32)) if len(all_16_32) > 0 else None
    overall_r_ge32 = (float(all_recalled_ge32) / len(all_ge32)) if len(all_ge32) > 0 else None

    summary = {
        "classes_with_gt": len(classes_with_gt),
        "mAP50": mAP50,
        "recall_h_lt16": overall_r_lt16,
        "recall_h_16_32": overall_r_16_32,
        "recall_h_ge32": overall_r_ge32,
        "gt_total": len(gt_records),
        "gt_h_lt16": len(all_lt16),
        "gt_h_16_32": len(all_16_32),
        "gt_h_ge32": len(all_ge32),
        "recalled_h_lt16": all_recalled_lt16,
        "recalled_h_16_32": all_recalled_16_32,
        "recalled_h_ge32": all_recalled_ge32,
    }

    return summary, per_class


def run_selftest():
    """Self-test for greedy matching and AP calculation logic without dataset."""
    gt_records = [
        {"img_idx": 0, "cls": 0, "box": (10.0, 10.0, 50.0, 50.0), "h": 40.0, "bucket": "ge32"},
        {"img_idx": 0, "cls": 0, "box": (100.0, 100.0, 150.0, 150.0), "h": 50.0, "bucket": "ge32"},
    ]

    pred_records = [
        {"img_idx": 0, "cls": 0, "conf": 0.90, "box": (10.0, 10.0, 50.0, 50.0)},
        {"img_idx": 0, "cls": 0, "conf": 0.80, "box": (10.0, 10.0, 50.0, 50.0)},
        {"img_idx": 0, "cls": 1, "conf": 0.70, "box": (100.0, 100.0, 150.0, 150.0)},
    ]

    summary, per_class = evaluate_predictions(
        gt_records, pred_records, num_classes=9, conf_op=0.25, iou_thresh=0.5
    )

    c0 = per_class[0]
    assert c0["gt"] == 2, f"Expected gt=2, got {c0['gt']}"
    assert c0["tp_total"] == 1, f"Expected tp_total=1, got {c0['tp_total']}"
    assert c0["fp_total"] == 1, f"Expected fp_total=1, got {c0['fp_total']}"
    expected_ap = 51.0 / 101.0
    assert abs(c0["ap50"] - expected_ap) < 1e-9, f"Expected ap50={expected_ap}, got {c0['ap50']}"
    assert c0["pred_op"] == 2, f"Expected pred_op=2, got {c0['pred_op']}"
    assert c0["tp_op"] == 1, f"Expected tp_op=1, got {c0['tp_op']}"
    assert c0["fp_op"] == 1, f"Expected fp_op=1, got {c0['fp_op']}"
    assert abs(c0["p_op"] - 0.5) < 1e-9, f"Expected p_op=0.5, got {c0['p_op']}"
    assert abs(c0["r_op"] - 0.5) < 1e-9, f"Expected r_op=0.5, got {c0['r_op']}"
    assert c0["recall_h_lt16"] is None
    assert c0["recall_h_16_32"] is None
    assert abs(c0["recall_h_ge32"] - 0.5) < 1e-9, f"Expected recall_h_ge32=0.5, got {c0['recall_h_ge32']}"

    c1 = per_class[1]
    assert c1["gt"] == 0, f"Expected gt=0, got {c1['gt']}"
    assert c1["tp_total"] == 0, f"Expected tp_total=0, got {c1['tp_total']}"
    assert c1["fp_total"] == 1, f"Expected fp_total=1, got {c1['fp_total']}"
    assert c1["ap50"] is None, f"Expected ap50=None, got {c1['ap50']}"
    assert c1["p_op"] == 0.0, f"Expected p_op=0.0, got {c1['p_op']}"
    assert c1["r_op"] is None, f"Expected r_op=None, got {c1['r_op']}"

    print("SELFTEST OK")


def load_dataset(data_yaml_path, split):
    """Load split image list from data.yaml."""
    import yaml

    if not os.path.isabs(data_yaml_path):
        data_yaml_path = os.path.join(PROJECT_ROOT, data_yaml_path)

    with open(data_yaml_path, "r", encoding="utf-8") as f:
        data_cfg = yaml.safe_load(f)

    base_dir = data_cfg.get("path")
    if not base_dir:
        base_dir = os.path.dirname(os.path.abspath(data_yaml_path))

    split_val = data_cfg.get(split)
    if not split_val:
        raise ValueError(f"Split '{split}' not found in {data_yaml_path}")

    if os.path.isabs(split_val):
        split_dir = split_val
    else:
        split_dir = os.path.join(base_dir, split_val)

    valid_exts = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff"}
    image_paths = []
    if os.path.isdir(split_dir):
        for fname in sorted(os.listdir(split_dir)):
            ext = os.path.splitext(fname)[1].lower()
            if ext in valid_exts:
                image_paths.append(os.path.join(split_dir, fname))
    elif os.path.isfile(split_dir):
        with open(split_dir, "r", encoding="utf-8") as f:
            for line in f:
                p = line.strip()
                if p:
                    if not os.path.isabs(p):
                        p = os.path.join(base_dir, p)
                    image_paths.append(p)
    else:
        raise FileNotFoundError(f"Image split path not found: {split_dir}")

    image_paths.sort()
    return data_cfg, image_paths


def load_ground_truth(image_paths):
    """Load and denormalize ground truth boxes from YOLO label txt files."""
    gt_records = []
    for img_idx, img_p in enumerate(image_paths):
        lbl_p = img_p.replace("/images/", "/labels/").replace("\\images\\", "\\labels\\")
        base, _ = os.path.splitext(lbl_p)
        lbl_p = base + ".txt"

        with Image.open(img_p) as im:
            img_w, img_h = im.size

        boxes = read_yolo_txt(lbl_p, img_w, img_h)
        for cls, x1, y1, x2, y2 in boxes:
            h = float(y2 - y1)
            if h < 16.0:
                bucket = "lt16"
            elif h < 32.0:
                bucket = "16_32"
            else:
                bucket = "ge32"
            gt_records.append({
                "img_idx": img_idx,
                "cls": int(cls),
                "box": (float(x1), float(y1), float(x2), float(y2)),
                "h": h,
                "bucket": bucket,
            })
    return gt_records


def predict_oracle(gt_records):
    """Oracle prediction: predictions equal ground truth with conf=1.0."""
    pred_records = []
    for g in gt_records:
        pred_records.append({
            "img_idx": g["img_idx"],
            "cls": g["cls"],
            "conf": 1.0,
            "box": g["box"],
        })
    return pred_records


def predict_coco(weights, image_paths, imgsz, conf, iou, device):
    """COCO baseline: run YOLOv8 on COCO classes and map via coco_to_project."""
    from ultralytics import YOLO

    model = YOLO(weights)
    results = model.predict(
        image_paths,
        batch=16,
        imgsz=imgsz,
        conf=conf,
        iou=iou,
        classes=[0, 1, 2, 3, 5, 7],
        agnostic_nms=False,
        device=device,
        verbose=False,
    )
    pred_records = []
    for img_idx, r in enumerate(results):
        dets = []
        if len(r.boxes) > 0:
            xyxy = r.boxes.xyxy.cpu().numpy()
            clss = r.boxes.cls.cpu().numpy()
            confs = r.boxes.conf.cpu().numpy()
            for box, c, cf in zip(xyxy, clss, confs):
                dets.append({
                    "coco_id": int(c),
                    "conf": float(cf),
                    "x1": float(box[0]),
                    "y1": float(box[1]),
                    "x2": float(box[2]),
                    "y2": float(box[3]),
                })
        proj = coco_to_project(dets, min_h_src=12.0)
        for p in proj:
            pred_records.append({
                "img_idx": img_idx,
                "cls": int(p["cls"]),
                "conf": float(p["conf"]),
                "box": (float(p["x1"]), float(p["y1"]), float(p["x2"]), float(p["y2"])),
            })
    return pred_records


def predict_model(weights, image_paths, imgsz, conf, iou, agnostic, device):
    """Trained 9-class model prediction."""
    from ultralytics import YOLO

    model = YOLO(weights)
    results = model.predict(
        image_paths,
        batch=16,
        imgsz=imgsz,
        conf=conf,
        iou=iou,
        agnostic_nms=agnostic,
        device=device,
        verbose=False,
    )
    pred_records = []
    for img_idx, r in enumerate(results):
        if len(r.boxes) > 0:
            xyxy = r.boxes.xyxy.cpu().numpy()
            clss = r.boxes.cls.cpu().numpy()
            confs = r.boxes.conf.cpu().numpy()
            for box, c, cf in zip(xyxy, clss, confs):
                pred_records.append({
                    "img_idx": img_idx,
                    "cls": int(c),
                    "conf": float(cf),
                    "box": (float(box[0]), float(box[1]), float(box[2]), float(box[3])),
                })
    return pred_records


def generate_report(params, summary, per_class, ultra_ap50_by_cls=None):
    """Generate Markdown report."""
    lines = []
    lines.append("GT 为教师伪标签（COCO yolov8s@1280 映射），指标表示与教师的一致程度，不等于真实识别准确率")
    lines.append("")
    lines.append(f"# Evaluation Report: {params['name']}")
    lines.append("")
    lines.append(f"- **Mode**: `{params['mode']}`")
    if params.get("weights"):
        lines.append(f"- **Weights**: `{params['weights']}`")
    lines.append(f"- **Data**: `{params['data']}` (split: `{params['split']}`, {summary['num_images']} images)")
    lines.append(f"- **Operating Point**: `conf >= {params['conf_op']:.2f}` (AP conf >= {params['conf']})")
    lines.append(f"- **NMS IoU**: `{params['iou']}` | **Class Agnostic**: `{params['agnostic']}`")
    lines.append("")
    lines.append("## Per-Class Metrics")
    lines.append("")

    has_ultra = (params["mode"] == "model" and ultra_ap50_by_cls is not None)
    if has_ultra:
        lines.append("| Class | GT | Pred (@op) | AP50 (ours) | AP50 (ultra) | P@op | R@op | R(<16) | R(16-32) | R(≥32) |")
        lines.append("| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |")
    else:
        lines.append("| Class | GT | Pred (@op) | AP50 | P@op | R@op | R(<16) | R(16-32) | R(≥32) |")
        lines.append("| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |")

    def fmt(v):
        if v is None:
            return "n/a"
        if isinstance(v, float):
            return f"{v:.4f}"
        return str(v)

    for c in range(len(per_class)):
        pc = per_class[c]
        row = [
            pc["name"],
            fmt(pc["gt"]),
            fmt(pc["pred_op"]),
        ]
        if has_ultra:
            u_ap = ultra_ap50_by_cls.get(c)
            row.extend([fmt(pc["ap50"]), fmt(u_ap)])
        else:
            row.append(fmt(pc["ap50"]))

        row.extend([
            fmt(pc["p_op"]),
            fmt(pc["r_op"]),
            fmt(pc["recall_h_lt16"]),
            fmt(pc["recall_h_16_32"]),
            fmt(pc["recall_h_ge32"]),
        ])
        lines.append("| " + " | ".join(row) + " |")

    lines.append("")
    lines.append("## Summary")
    lines.append("")
    if summary["mAP50"] is not None:
        lines.append(f"- **mAP50**: {summary['mAP50']:.4f} (over {summary['classes_with_gt']} classes with GT > 0)")
    else:
        lines.append("- **mAP50**: n/a")

    if has_ultra:
        ultra_map50 = None
        valid_u = [ultra_ap50_by_cls[c] for c in ultra_ap50_by_cls if c in per_class and per_class[c]["gt"] > 0]
        if valid_u:
            ultra_map50 = float(np.mean(valid_u))
        lines.append(f"- **mAP50 (ultra)**: {fmt(ultra_map50)}")

    def fmt_bucket(rec, tot, r):
        if tot == 0 or r is None:
            return f"n/a ({rec}/{tot})"
        return f"{r:.4f} ({rec}/{tot})"

    lines.append("- **Overall Recall by Height (@op)**:")
    lines.append(f"  - `<16 px`: {fmt_bucket(summary['recalled_h_lt16'], summary['gt_h_lt16'], summary['recall_h_lt16'])}")
    lines.append(f"  - `16–32 px`: {fmt_bucket(summary['recalled_h_16_32'], summary['gt_h_16_32'], summary['recall_h_16_32'])}")
    lines.append(f"  - `≥32 px`: {fmt_bucket(summary['recalled_h_ge32'], summary['gt_h_ge32'], summary['recall_h_ge32'])}")
    lines.append("")
    return "\n".join(lines)


def main():
    if "--selftest" in sys.argv:
        run_selftest()
        sys.exit(0)

    parser = argparse.ArgumentParser(description="Evaluate NPU Road-Band YOLO models.")
    parser.add_argument("--mode", choices=["model", "coco", "oracle"], required=True,
                        help="Evaluation mode: model, coco, or oracle")
    parser.add_argument("--name", required=True,
                        help="Run name for output directory under runs/npu_eval/<name>")
    parser.add_argument("--weights", default=None,
                        help="Path to model weights (required for 'model' and 'coco' modes)")
    parser.add_argument("--data", default="datasets/npu_v1w/data.yaml",
                        help="Path to data.yaml (default: datasets/npu_v1w/data.yaml)")
    parser.add_argument("--split", default="val",
                        help="Dataset split to evaluate on (default: val)")
    parser.add_argument("--imgsz", type=int, default=960,
                        help="Inference image size (default: 960)")
    parser.add_argument("--conf", type=float, default=0.001,
                        help="Confidence threshold for AP calculation (default: 0.001)")
    parser.add_argument("--conf-op", dest="conf_op", type=float, default=0.25,
                        help="Operating point confidence threshold (default: 0.25)")
    parser.add_argument("--iou", type=float, default=0.6,
                        help="NMS IoU threshold (default: 0.6)")
    parser.add_argument("--agnostic", dest="agnostic", action="store_true", default=True,
                        help="Class-agnostic NMS (default: True)")
    parser.add_argument("--no-agnostic", dest="agnostic", action="store_false",
                        help="Class-specific NMS")
    parser.add_argument("--device", default="cpu",
                        help="Device to run inference on (default: cpu)")
    parser.add_argument("--selftest", action="store_true",
                        help="Run self-test on matching and AP calculation logic")

    args = parser.parse_args()

    if args.mode in ("model", "coco") and not args.weights:
        parser.error(f"--weights is required when --mode is '{args.mode}'")

    if args.mode == "coco":
        args.agnostic = False

    runs_dir = os.path.join(PROJECT_ROOT, "runs", "npu_eval")
    out_dir = os.path.join(runs_dir, args.name)
    if os.path.exists(out_dir):
        sys.stderr.write(f"Error: Output directory already exists: {out_dir}\n")
        sys.exit(2)

    # Environment guard before importing ultralytics
    check_env()

    # Load dataset
    data_cfg, image_paths = load_dataset(args.data, args.split)
    gt_records = load_ground_truth(image_paths)

    # Predict according to mode
    if args.mode == "oracle":
        pred_records = predict_oracle(gt_records)
    elif args.mode == "coco":
        pred_records = predict_coco(
            weights=args.weights,
            image_paths=image_paths,
            imgsz=args.imgsz,
            conf=args.conf,
            iou=args.iou,
            device=args.device,
        )
    elif args.mode == "model":
        pred_records = predict_model(
            weights=args.weights,
            image_paths=image_paths,
            imgsz=args.imgsz,
            conf=args.conf,
            iou=args.iou,
            agnostic=args.agnostic,
            device=args.device,
        )
    else:
        raise ValueError(f"Unknown mode: {args.mode}")

    # Evaluate metrics using shared implementation
    summary, per_class = evaluate_predictions(
        gt_records=gt_records,
        pred_records=pred_records,
        num_classes=len(CLASS_NAMES),
        conf_op=args.conf_op,
        iou_thresh=0.5,
    )
    summary["num_images"] = len(image_paths)

    # Optional model mode cross-check using YOLO.val()
    ultra_ap50_by_cls = None
    if args.mode == "model":
        from ultralytics import YOLO
        ultra_project = runs_dir
        ultra_name = f"{args.name}_ultra"
        data_arg = args.data
        if not os.path.isabs(data_arg):
            data_arg = os.path.join(PROJECT_ROOT, data_arg)

        ultra_res = YOLO(args.weights).val(
            data=data_arg,
            split=args.split,
            imgsz=args.imgsz,
            rect=True,
            batch=16,
            conf=args.conf,
            iou=args.iou,
            device=args.device,
            plots=False,
            project=ultra_project,
            name=ultra_name,
        )
        ultra_ap50_by_cls = {}
        if ultra_res is not None and hasattr(ultra_res, "box"):
            for idx, c in enumerate(ultra_res.box.ap_class_index):
                ultra_ap50_by_cls[int(c)] = float(ultra_res.box.ap50[idx])

    # Save outputs
    os.makedirs(out_dir, exist_ok=False)

    metrics_data = {
        "params": vars(args),
        "summary": summary,
        "per_class": per_class,
    }
    if ultra_ap50_by_cls is not None:
        metrics_data["ultra_ap50_by_cls"] = ultra_ap50_by_cls

    metrics_path = os.path.join(out_dir, "metrics.json")
    with open(metrics_path, "w", encoding="utf-8") as f:
        json.dump(metrics_data, f, indent=2, ensure_ascii=False)

    report_text = generate_report(vars(args), summary, per_class, ultra_ap50_by_cls)
    report_path = os.path.join(out_dir, "report.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report_text)

    print(report_text)


if __name__ == "__main__":
    main()
