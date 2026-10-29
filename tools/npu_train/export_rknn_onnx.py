"""Export YOLOv8 to the Rockchip rknn_model_zoo 9-output ONNX layout.

Outputs per stride (8, 16, 32): box_s{s} (1, 4*reg_max, H, W) raw DFL
logits, cls_s{s} (1, nc, H, W) sigmoid scores, sum_s{s} (1, 1, H, W)
clamp(cls.sum(1), 0, 1).  The Detect head is patched per instance only.

CPU only: torch and onnxruntime are limited to 4 threads.
"""

import sys

sys.dont_write_bytecode = True

import argparse
import hashlib
import json
import os
import types
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
os.environ.setdefault("YOLO_CONFIG_DIR", str(ROOT / ".yolo_cfg"))
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "-1")

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rknn_postprocess as rp  # noqa: E402

STRIDES = (8, 16, 32)
PROFILES = {"band": (320, 960), "mosaic": (384, 640), "side": (224, 640)}
OUT_NAMES = [
    "%s_s%d" % (kind, s) for s in STRIDES for kind in ("box", "cls", "sum")
]
BAND_CROP = {"src_w": 1920, "src_h": 1080, "y0": 360, "y1": 1000}


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Export YOLOv8 to RKNN 9-output ONNX")
    ap.add_argument("--weights", "--pt", required=True, help="path to .pt weights")
    ap.add_argument("--profile", required=True, choices=sorted(PROFILES))
    ap.add_argument("--out", required=True, help="output .onnx path")
    ap.add_argument("--opset", type=int, default=12)
    ap.add_argument("--verify", action="store_true")
    ap.add_argument(
        "--verify-pool",
        default=str(ROOT / "video_review" / "label_pool"),
    )
    ap.add_argument("--verify-n", type=int, default=20)
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--iou", type=float, default=0.45)
    return ap.parse_args(argv)


def md5sum(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def detect_end2end_info(detect):
    """Report whether the Detect instance carries one2one / end2end branches."""
    has_one2one = hasattr(detect, "one2one_cv2") and hasattr(detect, "one2one_cv3")
    end2end_flag = bool(getattr(detect, "end2end", False))
    return end2end_flag, has_one2one


def patch_detect(detect):
    """Replace forward on this Detect instance only; returns an info dict."""
    import torch

    end2end_flag, has_one2one = detect_end2end_info(detect)

    def forward(self, x):
        outs = []
        for i in range(self.nl):
            box = self.cv2[i](x[i])
            cls = torch.sigmoid(self.cv3[i](x[i]))
            score_sum = torch.clamp(cls.sum(dim=1, keepdim=True), 0.0, 1.0)
            outs.extend([box, cls, score_sum])
        return tuple(outs)

    detect.forward = types.MethodType(forward, detect)
    return {
        "class": detect.__class__.__name__,
        "nl": int(detect.nl),
        "end2end_flag": end2end_flag,
        "has_one2one": has_one2one,
        "uses": "cv2/cv3 only",
    }


def load_fused_model(weights):
    from ultralytics import YOLO

    model = YOLO(weights).model
    model = model.float().eval()
    model = model.fuse(verbose=False)
    return model


def export_onnx(model, onnx_path, size, opset):
    import torch

    h, w = size
    dummy = torch.zeros(1, 3, h, w, dtype=torch.float32)
    with torch.inference_mode():
        torch.onnx.export(
            model,
            dummy,
            str(onnx_path),
            opset_version=opset,
            do_constant_folding=True,
            dynamo=False,
            input_names=["images"],
            output_names=OUT_NAMES,
            verbose=False,
        )


def fix_onnx(onnx_path):
    import onnx

    model = onnx.load(str(onnx_path))
    if model.ir_version > 8:
        model.ir_version = 8
        onnx.save(model, str(onnx_path))
    onnx.checker.check_model(str(onnx_path))
    model = onnx.load(str(onnx_path))
    shapes = {}
    for out in model.graph.output:
        dims = [int(d.dim_value) for d in out.type.tensor_type.shape.dim]
        shapes[out.name] = dims
    return {
        "opset": int(model.opset_import[0].version),
        "ir_version": int(model.ir_version),
        "shapes": shapes,
    }


def select_images(pool, n):
    """Pick n images spread evenly over the videos in pool."""
    pool = Path(pool)
    videos = sorted(p for p in pool.iterdir() if p.is_dir())
    groups = []
    for v in videos:
        files = sorted(v.glob("*.jpg"))
        if files:
            groups.append(files)
    if not groups:
        raise RuntimeError("no *.jpg found under %s" % pool)
    total = sum(len(g) for g in groups)
    n = max(0, min(int(n), total))
    nv = len(groups)
    quotas = [n // nv] * nv
    for i in range(n % nv):
        quotas[i] += 1
    remaining = n - sum(quotas)
    while remaining > 0:
        progressed = False
        for i in range(nv):
            if remaining == 0:
                break
            if quotas[i] < len(groups[i]):
                quotas[i] += 1
                remaining -= 1
                progressed = True
        if not progressed:
            break
    picked = []
    for files, q in zip(groups, quotas):
        if q <= 0:
            continue
        idx = np.linspace(0, len(files) - 1, q).round().astype(int)
        picked.extend(files[int(k)] for k in idx)
    return picked


def preprocess(path, profile):
    import cv2

    buf = np.fromfile(str(path), dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if img is None:
        raise RuntimeError("failed to decode %s" % path)
    h, w = PROFILES[profile]
    if profile == "band":
        img = img[BAND_CROP["y0"]: BAND_CROP["y1"], :, :]
        small = cv2.resize(img, (w, h), interpolation=cv2.INTER_AREA)
    else:
        small = cv2.resize(img, (w, h), interpolation=cv2.INTER_LINEAR)
    rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
    x = rgb.astype(np.float32) / 255.0
    x = np.transpose(x, (2, 0, 1))[None]
    return np.ascontiguousarray(x)


def make_ort_session(onnx_path):
    import onnxruntime as ort

    so = ort.SessionOptions()
    so.intra_op_num_threads = 4
    so.inter_op_num_threads = 1
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    return ort.InferenceSession(
        str(onnx_path), sess_options=so, providers=["CPUExecutionProvider"]
    )


def run_reference(model, x):
    import torch

    with torch.inference_mode():
        out = model(torch.from_numpy(x))
    pred = out[0] if isinstance(out, tuple) else out
    if not torch.is_tensor(pred):
        raise RuntimeError("unexpected reference output type: %r" % type(pred))
    pred = pred.detach().cpu().numpy()
    if pred.ndim != 3 or pred.shape[0] != 1:
        raise RuntimeError("unexpected reference shape: %r" % (pred.shape,))
    y = pred[0]  # (4 + nc, N)
    xywh = y[:4].T.astype(np.float32)
    scores = y[4:].T.astype(np.float32)
    boxes = np.stack(
        [
            xywh[:, 0] - xywh[:, 2] / 2.0,
            xywh[:, 1] - xywh[:, 3] / 2.0,
            xywh[:, 0] + xywh[:, 2] / 2.0,
            xywh[:, 1] + xywh[:, 3] / 2.0,
        ],
        axis=1,
    ).astype(np.float32)
    return boxes, scores


def run_onnx(session, x):
    names = [o.name for o in session.get_outputs()]
    vals = session.run(None, {"images": x})
    by_name = dict(zip(names, vals))
    missing = [n for n in OUT_NAMES if n not in by_name]
    if missing:
        raise RuntimeError("missing ONNX outputs: %s" % missing)
    return [by_name[n] for n in OUT_NAMES], by_name


def match_detections(rb, rs, rc, ob, os_, oc):
    """Every reference detection must have a same-class IoU>=0.99 partner."""
    if len(rb) == 0:
        return 0, 1.0
    unmatched = 0
    worst = 1.0
    for i in range(len(rb)):
        cand = np.flatnonzero(oc == rc[i])
        if cand.size == 0:
            unmatched += 1
            continue
        best = float(np.max(rp._iou_xyxy(rb[i], ob[cand])))
        worst = min(worst, best)
        if best < 0.99:
            unmatched += 1
    return unmatched, worst


def verify(onnx_path, weights, profile, args, nc):
    import torch

    torch.set_num_threads(4)
    images = select_images(args.verify_pool, args.verify_n)
    print("VERIFY: %d images from %s" % (len(images), args.verify_pool))

    ref_model = load_fused_model(weights)
    session = make_ort_session(onnx_path)

    worst = {
        "box": 0.0,
        "score": 0.0,
        "sum": 0.0,
        "count_diff": 0,
        "unmatched": 0,
        "min_iou": 1.0,
        "n": 0,
    }
    failures = []

    for k, path in enumerate(images, 1):
        x = preprocess(path, profile)
        rb, rs = run_reference(ref_model, x)
        outs, by_name = run_onnx(session, x)
        ob, os_ = rp.dfl_decode(outs, strides=STRIDES, reg_max=16)

        local = {}
        if rb.shape != ob.shape:
            failures.append("%s: anchor/box shape R%s vs O%s" % (path.name, rb.shape, ob.shape))
            continue
        if rs.shape != os_.shape:
            failures.append("%s: score shape R%s vs O%s" % (path.name, rs.shape, os_.shape))
            continue

        box_err = float(np.max(np.abs(rb - ob))) if rb.size else 0.0
        score_err = float(np.max(np.abs(rs - os_))) if rs.size else 0.0
        sum_err = 0.0
        for si, s in enumerate(STRIDES):
            cls_o = np.asarray(by_name["cls_s%d" % s], dtype=np.float32).reshape(1, nc, -1)
            sum_o = np.asarray(by_name["sum_s%d" % s], dtype=np.float32).reshape(1, 1, -1)
            ref_sum = np.clip(cls_o.sum(axis=1, keepdims=True), 0.0, 1.0)
            sum_err = max(sum_err, float(np.max(np.abs(ref_sum - sum_o))))

        rn_b, rn_s, rn_c = rp.nms(rb, rs, args.conf, args.iou)
        on_b, on_s, on_c = rp.nms(ob, os_, args.conf, args.iou)
        unmatched, min_iou = match_detections(rn_b, rn_s, rn_c, on_b, on_s, on_c)
        count_diff = abs(len(rn_b) - len(on_b))

        worst["box"] = max(worst["box"], box_err)
        worst["score"] = max(worst["score"], score_err)
        worst["sum"] = max(worst["sum"], sum_err)
        worst["count_diff"] = max(worst["count_diff"], count_diff)
        worst["unmatched"] = max(worst["unmatched"], unmatched)
        worst["min_iou"] = min(worst["min_iou"], min_iou)
        worst["n"] += 1
        local = dict(box=box_err, score=score_err, sum=sum_err,
                     nr=len(rn_b), no=len(on_b), unmatched=unmatched)

        ok = (
            box_err <= 0.1
            and score_err <= 1e-3
            and sum_err <= 1e-5
            and count_diff == 0
            and unmatched == 0
        )
        print(
            "[%2d/%2d] %-42s box=%.3e score=%.3e sum=%.3e detR=%d detO=%d %s"
            % (k, len(images), path.name, box_err, score_err, sum_err,
               len(rn_b), len(on_b), "OK" if ok else "FAIL")
        )
        if not ok:
            failures.append(
                "%s: box=%.6g score=%.6g sum=%.6g detR=%d detO=%d unmatched=%d"
                % (path.name, box_err, score_err, sum_err, len(rn_b), len(on_b), unmatched)
            )

    print("WORST: box_abs=%.6g px (<=0.1), score_abs=%.6g (<=1e-3), "
          "sum_abs=%.6g (<=1e-5), det_count_diff=%d, unmatched=%d, min_match_iou=%.6f"
          % (worst["box"], worst["score"], worst["sum"], worst["count_diff"],
             worst["unmatched"], worst["min_iou"]))

    ok = (
        worst["n"] == len(images)
        and worst["box"] <= 0.1
        and worst["score"] <= 1e-3
        and worst["sum"] <= 1e-5
        and worst["count_diff"] == 0
        and worst["unmatched"] == 0
    )
    if ok and not failures:
        print("VERIFY PASS")
        return 0
    print("VERIFY FAIL")
    for f in failures:
        print("  " + f)
    return 1


def main(argv=None):
    args = parse_args(argv)
    weights = Path(args.weights).resolve()
    out = Path(args.out)
    if not out.is_absolute():
        out = (ROOT / out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    h, w = PROFILES[args.profile]

    model = load_fused_model(str(weights))
    detect = model.model[-1]
    if detect.__class__.__name__ != "Detect":
        raise RuntimeError("last layer is %s, not Detect" % detect.__class__.__name__)
    info = patch_detect(detect)
    print(
        "DETECT: class=%s nl=%d end2end=%s one2one=%s patch=%s"
        % (info["class"], info["nl"], info["end2end_flag"],
           info["has_one2one"], info["uses"])
    )

    export_onnx(model, out, (h, w), args.opset)
    meta = fix_onnx(out)

    names_dict = model.names
    if isinstance(names_dict, dict):
        names = [names_dict[k] for k in sorted(names_dict)]
    else:
        names = list(names_dict)
    nc = len(names)

    print("ONNX: %s" % out)
    print("opset=%d ir_version=%d" % (meta["opset"], meta["ir_version"]))
    for name in OUT_NAMES:
        print("  %-8s %s" % (name, meta["shapes"].get(name)))

    side = {
        "weights": {"path": str(weights), "md5": md5sum(weights)},
        "profile": args.profile,
        "input": {
            "name": "images",
            "shape": [1, 3, h, w],
            "layout": "NCHW",
            "color": "RGB",
            "normalize": "x/255",
            "mean": [0, 0, 0],
            "std": [255, 255, 255],
        },
        "strides": list(STRIDES),
        "reg_max": 16,
        "nc": nc,
        "names": names,
        "outputs": [{"name": n, "shape": meta["shapes"].get(n)} for n in OUT_NAMES],
        "opset": meta["opset"],
        "ir_version": meta["ir_version"],
    }
    if args.profile == "band":
        side.update(BAND_CROP)
    json_path = Path(str(out) + ".json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(side, f, ensure_ascii=False, indent=2)
    print("JSON: %s" % json_path)

    if args.verify:
        return verify(out, str(weights), args.profile, args, nc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
