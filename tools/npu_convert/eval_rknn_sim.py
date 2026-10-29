"""Evaluate YOLOv8n Road-Band ONNX vs RKNN Simulator (FP & INT8).

Runs in the WSL conda environment 'rknn15' (Python 3.8).
Evaluates 73 validation images on:
  1. ONNX fp32 (onnxruntime)
  2. RKNN simulator FP (do_quantization=False)
  3. RKNN simulator INT8 (do_quantization=True, same calib & config as convert_rknn.py)
Decodes outputs with rknn_postprocess.dfl_decode and runs NMS with both:
  - agnostic
  - pr_split
Saves predictions as JSON files in runs/npu_eval/rknn_sim_b2f/ and calls
eval_metrics_wrapper.py (via yolov8_train python) to compute 101-point AP50 and generate report.md.
"""

import argparse
import glob
import json
import os
import subprocess
import sys
import time

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROJECT_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
_TRAIN_DIR = os.path.abspath(os.path.join(_HERE, "..", "npu_train"))
for d in (_HERE, _TRAIN_DIR):
    if d not in sys.path:
        sys.path.insert(0, d)

import convert_rknn
import rknn_postprocess


def parse_args():
    ap = argparse.ArgumentParser(description="Evaluate B2f model on RKNN simulator vs ONNX fp32.")
    ap.add_argument("--onnx", default="models/npu/b2f_v8n_band.onnx",
                    help="Path to ONNX model")
    ap.add_argument("--calib-dataset", default="models/npu/calib/band_960x320/dataset.txt",
                    help="Path to calibration dataset.txt")
    ap.add_argument("--val-dir", default="datasets/npu_v2w/images/val",
                    help="Directory containing validation images")
    ap.add_argument("--out-dir", default="runs/npu_eval/rknn_sim_b2f",
                    help="Output directory for predictions and report")
    ap.add_argument("--platform", default="rk3568",
                    help="Target platform (default: rk3568)")
    ap.add_argument("--conf", type=float, default=0.001,
                    help="NMS confidence threshold for AP calculation (default: 0.001)")
    ap.add_argument("--conf-op", type=float, default=0.25,
                    help="Operating point confidence threshold (default: 0.25)")
    ap.add_argument("--iou", type=float, default=0.6,
                    help="NMS IoU threshold (default: 0.6)")
    ap.add_argument("--max-det", type=int, default=300,
                    help="NMS max detections (default: 300)")
    ap.add_argument("--data", default="datasets/npu_v2w/data.yaml",
                    help="Path to data.yaml dataset definition")
    ap.add_argument("--wrapper-py",
                    default="/home/zdy/miniconda3/envs/yolov8_train/bin/python",
                    help="Python executable for yolov8_train environment")
    return ap.parse_args()


def log(msg):
    print(msg, flush=True)


def check_val_images(val_dir, expected_w=960, expected_h=320):
    val_dir = os.path.abspath(val_dir)
    if not os.path.isdir(val_dir):
        raise FileNotFoundError(f"Validation directory not found: {val_dir}")
    valid_exts = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
    paths = []
    for fname in sorted(os.listdir(val_dir)):
        ext = os.path.splitext(fname)[1].lower()
        if ext in valid_exts:
            paths.append(os.path.join(val_dir, fname))
    paths.sort()
    if not paths:
        raise ValueError(f"No valid images found in {val_dir}")

    log(f"Found {len(paths)} validation images in {val_dir}")
    import cv2
    for p in paths:
        buf = np.fromfile(p, dtype=np.uint8)
        img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        if img is None:
            raise IOError(f"Failed to read image: {p}")
        h, w = img.shape[:2]
        if (w, h) != (expected_w, expected_h):
            raise ValueError(
                f"Image size mismatch: {p} has shape {w}x{h} (WxH), expected {expected_w}x{expected_h}. "
                "Stopping as required by task instructions."
            )
    log(f"All {len(paths)} validation images verified as {expected_w}x{expected_h}.")
    return paths


def run_nms_both_modes(boxes, scores, conf_thres, iou_thres, max_det):
    """Run NMS with both agnostic and pr_split modes on decoded boxes."""
    b_ag, s_ag, c_ag = rknn_postprocess.nms(
        boxes, scores, conf_thres=conf_thres, iou_thres=iou_thres, max_det=max_det, mode="agnostic"
    )
    b_pr, s_pr, c_pr = rknn_postprocess.nms(
        boxes, scores, conf_thres=conf_thres, iou_thres=iou_thres, max_det=max_det, mode="pr_split"
    )
    return (b_ag, s_ag, c_ag), (b_pr, s_pr, c_pr)


def format_predictions(img_idx, boxes, scores, clss):
    records = []
    for b, s, c in zip(boxes, scores, clss):
        records.append({
            "img_idx": int(img_idx),
            "cls": int(c),
            "conf": float(s),
            "box": [float(b[0]), float(b[1]), float(b[2]), float(b[3])],
        })
    return records


def run_onnx_inference(onnx_path, meta, img_paths, conf_thres, iou_thres, max_det):
    log("[1/3] Running ONNX fp32 inference (onnxruntime)...")
    try:
        import onnxruntime as ort
    except ImportError as exc:
        log("ERROR: onnxruntime not found in current environment. Stopping as instructed.")
        raise exc

    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    input_name = sess.get_inputs()[0].name

    preds_ag = []
    preds_pr = []
    t0 = time.perf_counter()

    for idx, p in enumerate(img_paths):
        img = convert_rknn.read_rgb(p)
        # NCHW float / 255.0
        inp = np.transpose(img, (2, 0, 1))[None].astype(np.float32) / 255.0
        raw_outs = [np.asarray(o) for o in sess.run(None, {input_name: inp})]
        b, s = rknn_postprocess.dfl_decode(raw_outs, meta["strides"], meta["reg_max"])
        (b_ag, s_ag, c_ag), (b_pr, s_pr, c_pr) = run_nms_both_modes(
            b, s, conf_thres, iou_thres, max_det
        )
        preds_ag.extend(format_predictions(idx, b_ag, s_ag, c_ag))
        preds_pr.extend(format_predictions(idx, b_pr, s_pr, c_pr))

    dur = time.perf_counter() - t0
    log(f"ONNX fp32 finished in {dur:.2f}s (agnostic dets: {len(preds_ag)}, pr_split dets: {len(preds_pr)})")
    return preds_ag, preds_pr


def run_rknn_inference(onnx_path, meta, img_paths, do_quantization, calib_dataset_resolved,
                       config_kwargs, conf_thres, iou_thres, max_det, desc):
    log(f"[{desc}] Initializing RKNN (do_quantization={do_quantization})...")
    from rknn.api import RKNN

    rknn = RKNN(verbose=False)
    try:
        rknn.config(**config_kwargs)
        ret = rknn.load_onnx(model=onnx_path)
        if ret != 0:
            raise RuntimeError(f"rknn.load_onnx failed with ret={ret}")

        t0_build = time.perf_counter()
        ret = rknn.build(
            do_quantization=do_quantization,
            dataset=calib_dataset_resolved if do_quantization else None,
        )
        if ret != 0:
            raise RuntimeError(f"rknn.build failed with ret={ret}")
        log(f"[{desc}] build OK ({time.perf_counter() - t0_build:.1f}s)")

        ret = rknn.init_runtime()
        if ret != 0:
            raise RuntimeError(f"rknn.init_runtime failed with ret={ret}")
        log(f"[{desc}] init_runtime OK (simulator)")

        preds_ag = []
        preds_pr = []
        t0_infer = time.perf_counter()

        for idx, p in enumerate(img_paths):
            img = convert_rknn.read_rgb(p)
            # NHWC uint8 input (1, 320, 960, 3)
            raw = rknn.inference(inputs=[img[None]], data_format="nhwc")
            rk_outs = convert_rknn.coerce_outputs(raw, meta["outputs"])
            b, s = rknn_postprocess.dfl_decode(rk_outs, meta["strides"], meta["reg_max"])
            (b_ag, s_ag, c_ag), (b_pr, s_pr, c_pr) = run_nms_both_modes(
                b, s, conf_thres, iou_thres, max_det
            )
            preds_ag.extend(format_predictions(idx, b_ag, s_ag, c_ag))
            preds_pr.extend(format_predictions(idx, b_pr, s_pr, c_pr))

        dur = time.perf_counter() - t0_infer
        log(f"[{desc}] inference finished in {dur:.2f}s (agnostic dets: {len(preds_ag)}, pr_split dets: {len(preds_pr)})")
        return preds_ag, preds_pr
    finally:
        try:
            rknn.release()
        except Exception:
            pass


def main():
    args = parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    # 1. Check paths & inputs
    onnx_path = os.path.abspath(args.onnx)
    if not os.path.isfile(onnx_path):
        raise FileNotFoundError(f"ONNX not found: {onnx_path}")
    meta = convert_rknn.load_meta(onnx_path)
    log(f"Model meta loaded: W={meta['w']}, H={meta['h']}, nc={meta['nc']}, strides={meta['strides']}")

    calib_path = os.path.abspath(args.calib_dataset)
    _, calib_items = convert_rknn.parse_dataset(calib_path)
    log(f"Calibration dataset loaded: {len(calib_items)} images from {calib_path}")

    # Check validation images
    img_paths = check_val_images(args.val_dir, expected_w=meta["w"], expected_h=meta["h"])

    # Prepare resolved dataset for RKNN
    resolved_dataset = convert_rknn.write_resolved(
        os.path.join(args.out_dir, "b2f_eval.rknn"), calib_items
    )

    config_kwargs = {
        "mean_values": [[0, 0, 0]],
        "std_values": [[255, 255, 255]],
        "target_platform": args.platform,
        "quantized_dtype": "asymmetric_quantized-8",
        "quantized_algorithm": "normal",
        "quantized_method": "channel",
        "optimization_level": 3,
    }

    # Step A: ONNX fp32
    on_ag, on_pr = run_onnx_inference(
        onnx_path, meta, img_paths, args.conf, args.iou, args.max_det
    )
    with open(os.path.join(args.out_dir, "predictions_onnx_fp32_agnostic.json"), "w", encoding="utf-8") as f:
        json.dump(on_ag, f)
    with open(os.path.join(args.out_dir, "predictions_onnx_fp32_pr_split.json"), "w", encoding="utf-8") as f:
        json.dump(on_pr, f)

    # Step B: RKNN FP
    rk_fp_ag, rk_fp_pr = run_rknn_inference(
        onnx_path, meta, img_paths, do_quantization=False, calib_dataset_resolved=None,
        config_kwargs=config_kwargs, conf_thres=args.conf, iou_thres=args.iou, max_det=args.max_det,
        desc="2/3 RKNN FP",
    )
    with open(os.path.join(args.out_dir, "predictions_rknn_fp_agnostic.json"), "w", encoding="utf-8") as f:
        json.dump(rk_fp_ag, f)
    with open(os.path.join(args.out_dir, "predictions_rknn_fp_pr_split.json"), "w", encoding="utf-8") as f:
        json.dump(rk_fp_pr, f)

    # Step C: RKNN INT8
    rk_i8_ag, rk_i8_pr = run_rknn_inference(
        onnx_path, meta, img_paths, do_quantization=True, calib_dataset_resolved=resolved_dataset,
        config_kwargs=config_kwargs, conf_thres=args.conf, iou_thres=args.iou, max_det=args.max_det,
        desc="3/3 RKNN INT8",
    )
    with open(os.path.join(args.out_dir, "predictions_rknn_int8_agnostic.json"), "w", encoding="utf-8") as f:
        json.dump(rk_i8_ag, f)
    with open(os.path.join(args.out_dir, "predictions_rknn_int8_pr_split.json"), "w", encoding="utf-8") as f:
        json.dump(rk_i8_pr, f)

    log("All 6 prediction JSON files saved successfully.")

    # Step D: Call eval_metrics_wrapper.py to evaluate and generate report.md
    wrapper_script = os.path.join(_HERE, "eval_metrics_wrapper.py")
    py_exec = args.wrapper_py
    if not os.path.isfile(py_exec):
        py_exec = sys.executable

    log(f"Evaluating predictions using {wrapper_script} with {py_exec}...")
    cmd = [
        py_exec,
        wrapper_script,
        "--eval-dir", args.out_dir,
        "--data", args.data,
        "--split", "val",
        "--conf-op", str(args.conf_op),
    ]
    env = os.environ.copy()
    env["CUDA_VISIBLE_DEVICES"] = ""
    res = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        log("ERROR running eval_metrics_wrapper:")
        log(res.stderr)
        return res.returncode
    log(res.stdout)

    # Step E: Check if INT8 drop > 3.0 percentage points
    metrics_path = os.path.join(args.out_dir, "metrics_all.json")
    if os.path.isfile(metrics_path):
        with open(metrics_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        drops = data.get("drops", {})
        max_drop = max(drops.values()) if drops else 0.0
        log(f"Max INT8 mAP50 drop: {max_drop * 100:+.2f}%")
        if max_drop > 0.030:
            log("WARNING: INT8 mAP50 drop > 3.0 percentage points! Checking accuracy analysis...")
            acc_dir = os.path.join(args.out_dir, "accuracy_analysis")
            acc_target_dir = os.path.join(acc_dir, "b2f.rknn_acc")
            # If not yet generated, run convert_rknn.py with accuracy_analysis
            if not (os.path.isdir(os.path.join(acc_target_dir, "golden", "npy")) and
                    os.path.isdir(os.path.join(acc_target_dir, "simulator", "npy"))):
                os.makedirs(acc_dir, exist_ok=True)
                acc_cmd = [
                    sys.executable,
                    os.path.join(_HERE, "convert_rknn.py"),
                    "--onnx", args.onnx,
                    "--dataset", args.calib_dataset,
                    "--out", os.path.join(acc_dir, "b2f.rknn"),
                    "--accuracy-analysis", "1",
                ]
                log("Running convert_rknn.py --accuracy-analysis 1...")
                acc_res = subprocess.run(acc_cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                log(acc_res.stdout)
                if acc_res.returncode != 0:
                    log(f"accuracy_analysis error: {acc_res.stderr}")

            # Re-run eval_metrics_wrapper to include the accuracy analysis section in report.md
            subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    log("eval_rknn_sim completed successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
