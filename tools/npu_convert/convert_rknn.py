"""Convert a 9-output YOLOv8n ONNX to RKNN for RK3568 (RKNN-Toolkit2 1.5.x).

Runs inside WSL2 Ubuntu 22.04 / Python 3.10 where rknn-toolkit2 is installed.
Only the standard library and numpy are imported at module level; rknn,
onnxruntime and cv2 are imported lazily inside the functions that need them.

    python tools/npu_convert/convert_rknn.py \
        --onnx models/npu/onnx_test/yolov8n_coco_band_960x320.onnx \
        --dataset models/npu/calib/band_960x320/dataset.txt \
        --out models/npu/onnx_test/yolov8n_coco_band_960x320.rknn --dry-run
"""

import argparse
import hashlib
import importlib.metadata
import json
import os
import sys
import time

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_TRAIN_DIR = os.path.normpath(os.path.join(_HERE, "..", "npu_train"))
if _TRAIN_DIR not in sys.path:
    sys.path.insert(0, _TRAIN_DIR)

import rknn_postprocess  # noqa: E402  (local numpy-only decoder)

PNG_SIG = b"\x89PNG\r\n\x1a\n"


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="YOLOv8n ONNX -> RKNN (Toolkit2 1.5)")
    ap.add_argument("--onnx", required=True)
    ap.add_argument("--dataset", default=None)
    ap.add_argument("--out", required=True)
    ap.add_argument("--platform", default="rk3568")
    ap.add_argument("--quant", default="i8", choices=["i8", "fp"])
    ap.add_argument("--algo", default="normal",
                    choices=["normal", "mmse", "kl_divergence"])
    ap.add_argument("--method", default="channel", choices=["channel", "layer"])
    ap.add_argument("--opt-level", type=int, default=3)
    ap.add_argument("--sim-check", type=int, default=0)
    ap.add_argument("--accuracy-analysis", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true")
    return ap.parse_args(argv)


def log(msg):
    print(msg, flush=True)


def load_meta(onnx_path):
    meta_path = onnx_path + ".json"
    if not os.path.isfile(meta_path):
        raise FileNotFoundError("sidecar annotation not found: %s" % meta_path)
    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)
    shape = meta["input"]["shape"]
    if len(shape) != 4:
        raise ValueError("input.shape must be 4D, got %r" % (shape,))
    return {
        "path": meta_path,
        "raw": meta,
        "h": int(shape[2]),
        "w": int(shape[3]),
        "nc": int(meta["nc"]),
        "strides": tuple(int(s) for s in meta["strides"]),
        "reg_max": int(meta.get("reg_max", 16)),
        "outputs": [list(o["shape"]) for o in meta.get("outputs", [])],
        "names": list(meta.get("names", [])),
    }


def parse_dataset(dataset_path):
    dataset_path = os.path.abspath(dataset_path)
    if not os.path.isfile(dataset_path):
        raise FileNotFoundError("dataset not found: %s" % dataset_path)
    root = os.path.dirname(dataset_path)
    items = []
    with open(dataset_path, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            path = line if os.path.isabs(line) else os.path.normpath(os.path.join(root, line))
            if not os.path.isfile(path):
                raise FileNotFoundError("dataset line %d: missing %s" % (lineno, path))
            items.append(path)
    if not items:
        raise ValueError("dataset is empty: %s" % dataset_path)
    return dataset_path, items


def write_resolved(out_path, items):
    out_dir = os.path.dirname(os.path.abspath(out_path))
    os.makedirs(out_dir, exist_ok=True)
    resolved = os.path.join(out_dir, "_dataset_resolved.txt")
    with open(resolved, "w", encoding="utf-8", newline="\n") as f:
        for path in items:
            f.write(path + "\n")
    return resolved


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(33)
    if len(head) < 33 or head[:8] != PNG_SIG or head[12:16] != b"IHDR":
        raise ValueError("not a PNG (or truncated IHDR): %s" % path)
    width = int.from_bytes(head[16:20], "big")
    height = int.from_bytes(head[20:24], "big")
    bit_depth = head[24]
    color_type = head[25]
    return width, height, bit_depth, color_type


def check_first_image(items, meta):
    w, h, bit_depth, color_type = png_size(items[0])
    if (w, h) != (meta["w"], meta["h"]):
        raise ValueError(
            "calibration image size mismatch: %s is %dx%d (WxH), model expects %dx%d"
            % (items[0], w, h, meta["w"], meta["h"])
        )
    log("first calib image OK: %dx%d WxH, bit_depth=%d color_type=%d (%s)"
        % (w, h, bit_depth, color_type, os.path.basename(items[0])))
    return (w, h)


def md5_file(path, chunk=1 << 20):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while True:
            buf = f.read(chunk)
            if not buf:
                break
            h.update(buf)
    return h.hexdigest()


def rknn_version():
    for name in ("rknn-toolkit2", "rknn_toolkit2"):
        try:
            return "%s %s" % (name, importlib.metadata.version(name))
        except importlib.metadata.PackageNotFoundError:
            continue
        except Exception:
            continue
    return None


def read_rgb(path):
    import cv2

    buf = np.fromfile(path, dtype=np.uint8)
    bgr = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if bgr is None:
        raise IOError("cv2.imdecode failed: %s" % path)
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)


def coerce_outputs(outs, expected):
    """Return 9 float32 NCHW arrays; tolerate NHWC output layout."""
    out = []
    for i, arr in enumerate(outs):
        a = np.asarray(arr)
        if expected and i < len(expected) and a.ndim == 4:
            exp = tuple(int(x) for x in expected[i])
            if a.shape != exp and a.shape == (exp[0], exp[2], exp[3], exp[1]):
                a = np.transpose(a, (0, 3, 1, 2))
        out.append(np.ascontiguousarray(a, dtype=np.float32))
    return out


def iou_one_to_many(box, boxes):
    if boxes.shape[0] == 0:
        return np.zeros((0,), dtype=np.float32)
    x1 = np.maximum(box[0], boxes[:, 0])
    y1 = np.maximum(box[1], boxes[:, 1])
    x2 = np.minimum(box[2], boxes[:, 2])
    y2 = np.minimum(box[3], boxes[:, 3])
    iw = np.maximum(x2 - x1, 0.0)
    ih = np.maximum(y2 - y1, 0.0)
    inter = iw * ih
    area_a = max(box[2] - box[0], 0.0) * max(box[3] - box[1], 0.0)
    area_b = np.maximum(boxes[:, 2] - boxes[:, 0], 0.0) * np.maximum(
        boxes[:, 3] - boxes[:, 1], 0.0)
    union = area_a + area_b - inter
    return np.where(union > 0.0, inter / np.maximum(union, 1e-12), 0.0).astype(np.float32)


def cosine(a, b):
    a = np.asarray(a, dtype=np.float64).reshape(-1)
    b = np.asarray(b, dtype=np.float64).reshape(-1)
    if a.shape != b.shape:
        return None
    na = float(np.linalg.norm(a))
    nb = float(np.linalg.norm(b))
    if na == 0.0 or nb == 0.0:
        return None
    return float(np.dot(a, b) / (na * nb))


def class_counts(cls, names):
    counts = {}
    for c in np.asarray(cls).reshape(-1).tolist():
        name = names[c] if 0 <= c < len(names) else str(c)
        counts[name] = counts.get(name, 0) + 1
    return counts


def match_stats(onnx_boxes, onnx_cls, rknn_boxes, rknn_cls, iou_thres=0.5):
    total = int(len(onnx_cls))
    if total == 0:
        return {"onnx_dets": 0, "matched": 0, "match_rate": 1.0, "mean_iou": None}
    matched = 0
    ious = []
    for i in range(total):
        cand = np.flatnonzero(rknn_cls == onnx_cls[i])
        if cand.size == 0:
            continue
        iou = iou_one_to_many(onnx_boxes[i], rknn_boxes[cand])
        best = float(iou.max())
        if best >= iou_thres:
            matched += 1
            ious.append(best)
    return {
        "onnx_dets": total,
        "rknn_dets": int(len(rknn_cls)),
        "matched": matched,
        "match_rate": matched / float(total),
        "mean_iou": (float(np.mean(ious)) if ious else None),
    }


def run_sim_check(rknn, items, onnx_path, meta, n, out_path):
    import cv2  # noqa: F401  (kept lazy: only needed here)

    log("[sim-check] init_runtime() (simulator, no target)")
    ret = rknn.init_runtime()
    if ret != 0:
        log("[sim-check] init_runtime failed: ret=%s" % ret)
        return {"error": "init_runtime ret=%s" % ret}

    ort = None
    try:
        import onnxruntime as ort_mod
        ort = ort_mod
        sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
        input_name = sess.get_inputs()[0].name
        log("[sim-check] onnxruntime %s, input=%s" % (ort_mod.__version__, input_name))
    except Exception as exc:  # noqa: BLE001
        log("[sim-check] SKIP onnx comparison: %s" % exc)
        sess = None
        input_name = None

    names = meta["names"]
    records = []
    cos_all = [[] for _ in range(9)]
    for i, path in enumerate(items[:n]):
        img = read_rgb(path)
        if (img.shape[1], img.shape[0]) != (meta["w"], meta["h"]):
            log("[sim-check] skip %s: shape %r != (%d, %d)"
                % (os.path.basename(path), img.shape, meta["h"], meta["w"]))
            continue
        rk_outs = coerce_outputs(
            rknn.inference(inputs=[img], data_format="nhwc"), meta["outputs"])
        rk_b, rk_s = rknn_postprocess.dfl_decode(rk_outs, meta["strides"], meta["reg_max"])
        rb, rs, rc = rknn_postprocess.nms(rk_b, rk_s, conf_thres=0.25, iou_thres=0.45)
        rec = {"image": os.path.basename(path), "rknn_class_counts": class_counts(rc, names)}

        if sess is not None:
            inp = np.transpose(img, (2, 0, 1))[None].astype(np.float32) / 255.0
            on_outs = [np.asarray(o) for o in sess.run(None, {input_name: inp})]
            on_b, on_s = rknn_postprocess.dfl_decode(on_outs, meta["strides"], meta["reg_max"])
            ob, os_, oc = rknn_postprocess.nms(on_b, on_s, conf_thres=0.25, iou_thres=0.45)
            rec["onnx_class_counts"] = class_counts(oc, names)
            rec.update(match_stats(ob, oc, rb, rc))
            rec["cosine"] = []
            for k in range(min(9, len(on_outs), len(rk_outs))):
                c = cosine(on_outs[k], rk_outs[k])
                rec["cosine"].append(c)
                if c is not None:
                    cos_all[k].append(c)
        records.append(rec)
        log("[sim-check] %d/%d %s" % (i + 1, min(n, len(items)), rec["image"]))

    summary = {"images": records, "cosine_mean": [], "cosine_min": []}
    for k in range(9):
        if cos_all[k]:
            summary["cosine_mean"].append(float(np.mean(cos_all[k])))
            summary["cosine_min"].append(float(np.min(cos_all[k])))
        else:
            summary["cosine_mean"].append(None)
            summary["cosine_min"].append(None)
    if records and "match_rate" in records[0]:
        rates = [r["match_rate"] for r in records if "match_rate" in r]
        ious = [r["mean_iou"] for r in records if r.get("mean_iou") is not None]
        summary["match_rate_mean"] = float(np.mean(rates)) if rates else None
        summary["mean_iou_mean"] = float(np.mean(ious)) if ious else None
    else:
        summary["match_rate_mean"] = None
        summary["mean_iou_mean"] = None
    summary["note"] = "report only, no hard threshold"

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    log("[sim-check] match_rate_mean=%s mean_iou=%s cosine_mean=%s"
        % (summary["match_rate_mean"], summary["mean_iou_mean"],
           [None if c is None else round(c, 5) for c in summary["cosine_mean"]]))
    return summary


def main(argv=None):
    args = parse_args(argv)
    started = time.perf_counter()
    report = {
        "params": {
            "onnx": os.path.abspath(args.onnx),
            "dataset": os.path.abspath(args.dataset) if args.dataset else None,
            "out": os.path.abspath(args.out),
            "platform": args.platform,
            "quant": args.quant,
            "algo": args.algo,
            "method": args.method,
            "opt_level": args.opt_level,
            "sim_check": args.sim_check,
            "accuracy_analysis": args.accuracy_analysis,
            "dry_run": bool(args.dry_run),
        },
        "rknn_version": rknn_version(),
        "steps": {},
        "durations": {},
    }

    try:
        if not os.path.isfile(args.onnx):
            raise FileNotFoundError("onnx not found: %s" % args.onnx)
        meta = load_meta(args.onnx)
        log("onnx : %s" % os.path.abspath(args.onnx))
        log("meta : H=%d W=%d nc=%d strides=%r reg_max=%d"
            % (meta["h"], meta["w"], meta["nc"], meta["strides"], meta["reg_max"]))

        dataset_path = None
        items = []
        if args.dataset:
            dataset_path, items = parse_dataset(args.dataset)
            report["dataset"] = {"path": dataset_path, "count": len(items)}
            log("dataset: %d images from %s" % (len(items), dataset_path))
        elif args.quant == "i8" or args.dry_run:
            raise ValueError("--dataset is required (quant=%s)" % args.quant)

        first_size = check_first_image(items, meta) if items else None
        report["first_image_size"] = list(first_size) if first_size else None

        config_kwargs = {
            "mean_values": [[0, 0, 0]],
            "std_values": [[255, 255, 255]],
            "target_platform": args.platform,
            "quantized_dtype": "asymmetric_quantized-8",
            "quantized_algorithm": args.algo,
            "quantized_method": args.method,
            "optimization_level": args.opt_level,
        }
        report["config_kwargs"] = config_kwargs

        if args.dry_run:
            log("config(): %s" % json.dumps(config_kwargs, ensure_ascii=False))
            log("load_onnx(model=%r)" % os.path.abspath(args.onnx))
            log("build(do_quantization=%r, dataset=%r)"
                % (args.quant == "i8", "<resolved %d images>" % len(items)
                   if items else "<none>"))
            log("export_rknn(%r)" % os.path.abspath(args.out))
            log("DRY-RUN OK")
            report["result"] = "dry-run ok"
            report["total_seconds"] = time.perf_counter() - started
            return 0

        resolved = None
        if items:
            resolved = write_resolved(args.out, items)
            log("resolved dataset list: %s" % resolved)

        from rknn.api import RKNN

        rknn = RKNN(verbose=True)

        def step(name, fn):
            t0 = time.perf_counter()
            ret = fn()
            report["durations"][name] = round(time.perf_counter() - t0, 3)
            report["steps"][name] = ret
            if ret not in (0, None):  # config() may return None in Toolkit2
                log("step %s failed: ret=%s" % (name, ret))
                raise SystemExit(1)
            log("step %s ok: ret=%s (%.1fs)"
                % (name, ret, report["durations"][name]))
            return ret

        try:
            step("config", lambda: rknn.config(**config_kwargs))
            step("load_onnx", lambda: rknn.load_onnx(model=os.path.abspath(args.onnx)))
            step("build", lambda: rknn.build(
                do_quantization=(args.quant == "i8"),
                dataset=resolved if items else None,
            ))
            step("export_rknn", lambda: rknn.export_rknn(os.path.abspath(args.out)))

            if args.sim_check > 0 and items:
                t0 = time.perf_counter()
                try:
                    sim = run_sim_check(rknn, items, os.path.abspath(args.onnx),
                                        meta, args.sim_check, args.out + ".simcheck.json")
                    report["sim_check"] = {"path": os.path.abspath(args.out) + ".simcheck.json",
                                           "summary": {k: v for k, v in sim.items()
                                                       if k != "images"}}
                finally:
                    report["durations"]["sim_check"] = round(time.perf_counter() - t0, 3)

            if args.accuracy_analysis > 0 and items:
                acc_dir = os.path.abspath(args.out) + "_acc"
                t0 = time.perf_counter()
                ret = rknn.accuracy_analysis(inputs=[items[0]], output_dir=acc_dir)
                report["durations"]["accuracy_analysis"] = round(time.perf_counter() - t0, 3)
                report["steps"]["accuracy_analysis"] = ret
                log("accuracy_analysis ret=%s -> %s" % (ret, acc_dir))
        finally:
            t0 = time.perf_counter()
            try:
                rknn.release()
                report["steps"]["release"] = 0
            except Exception as exc:  # noqa: BLE001
                report["steps"]["release"] = "error: %s" % exc
            report["durations"]["release"] = round(time.perf_counter() - t0, 3)

        report["onnx_md5"] = md5_file(args.onnx)
        if os.path.isfile(args.out):
            report["rknn_size"] = os.path.getsize(args.out)
        report["result"] = "ok"
        report["total_seconds"] = round(time.perf_counter() - started, 3)
        with open(args.out + ".convert.json", "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        log("converted -> %s" % os.path.abspath(args.out))
        return 0
    except (ValueError, FileNotFoundError, IOError) as exc:
        log("ERROR: %s" % exc)
        return 1
    except SystemExit as exc:
        report["result"] = "failed"
        report["total_seconds"] = round(time.perf_counter() - started, 3)
        try:
            with open(args.out + ".convert.json", "w", encoding="utf-8") as f:
                json.dump(report, f, ensure_ascii=False, indent=2)
        except Exception:
            pass
        return int(exc.code or 1)


if __name__ == "__main__":
    sys.exit(main())
