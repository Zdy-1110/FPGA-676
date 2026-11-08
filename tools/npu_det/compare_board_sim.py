#!/usr/bin/env python3
"""Compare board-side npu_det results (CSV) against the RKNN toolkit simulator on PC.

Two modes:

video
    Decode --video with OpenCV (frame index = decode order, same convention as the
    board), crop y in [360, 1000) at full width, resize to 960x320 with
    INTER_AREA and convert BGR->RGB. Only frames present in --board-csv are
    processed, then thinned by --stride/--limit. Each crop goes through the INT8
    RKNN simulator (built from the ONNX with the same config/calibration as
    convert_rknn.py), post-processing is identical to the board
    (pr_split, conf 0.25, IoU 0.6, max_det 300) and boxes are mapped back to
    the 1920x1080 source frame (x*2, y*2+360, clamped like npu_map_to_src).
    Board and simulator boxes are matched per frame per class by score-greedy
    assignment with IoU >= 0.5.

rgb
    Compare a board dump (960x320x3 raw RGB, e.g. npu_det --dump-rgb) with the
    PC crops of frames N-2..N+2 (per-channel MAE / max abs diff / PSNR) to check
    frame alignment, then run the simulator on the dump itself and match the
    resulting boxes against the board CSV row set of frame N.

Both modes write a JSON report to log/npu_det/compare/.

Runs in the WSL conda environment 'rknn15' (rknn-toolkit2 1.5.0, Python 3.8).
Existing helpers are imported, not modified:
    tools/npu_convert/convert_rknn.py   (load_meta / parse_dataset / write_resolved / coerce_outputs)
    tools/npu_train/rknn_postprocess.py (dfl_decode / nms)
"""

import argparse
import csv
import json
import os
import sys
import time

import cv2
import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
for _d in (os.path.join(_ROOT, "tools", "npu_convert"),
           os.path.join(_ROOT, "tools", "npu_train")):
    if _d not in sys.path:
        sys.path.insert(0, _d)

import convert_rknn
import rknn_postprocess

# --- board pipeline geometry ---
SRC_W, SRC_H = 1920, 1080
CROP_X, CROP_Y, CROP_W, CROP_H = 0, 360, 1920, 640
NET_W, NET_H = 960, 320
SCALE_X = float(CROP_W) / float(NET_W)   # 2.0
SCALE_Y = float(CROP_H) / float(NET_H)   # 2.0

MODELS = {
    "b2f": "models/npu/b2f_v8n_band.onnx",
    "b3f": "models/npu/b3f_v8n_band.onnx",
}
CSV_FIELDS = ["frame", "time_ms", "cls", "score", "x0", "y0", "x1", "y1"]
DEFAULT_CALIB = "models/npu/calib/band_960x320/dataset.txt"
DEFAULT_OUT_DIR = "log/npu_det/compare"
MATCH_IOU = 0.5


def log(msg):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def resolve(path):
    """Resolve a CLI path against the project root when it is relative."""
    if os.path.isabs(path):
        return path
    return os.path.normpath(os.path.join(_ROOT, path))


def parse_args(argv=None):
    ap = argparse.ArgumentParser(
        description="Compare board npu_det CSV results with the RKNN simulator.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--mode", choices=["auto", "video", "rgb"], default="auto",
                    help="auto: rgb mode when --rgb is given, otherwise video mode")
    ap.add_argument("--model", required=True, choices=sorted(MODELS),
                    help="which trained model the board ran")
    ap.add_argument("--board-csv", default=None,
                    help="board CSV (frame,time_ms,cls,score,x0,y0,x1,y1)")
    ap.add_argument("--video", default=None,
                    help="source video decoded on the board")
    ap.add_argument("--stride", type=int, default=1, help="video mode: frame stride")
    ap.add_argument("--limit", type=int, default=0,
                    help="video mode: max frames after stride (0 = all)")
    ap.add_argument("--rgb", default=None,
                    help="rgb mode: raw 960x320x3 RGB dump from the board")
    ap.add_argument("--frame", type=int, default=None,
                    help="rgb mode: board frame index the dump belongs to")
    ap.add_argument("--calib", default=DEFAULT_CALIB,
                    help="INT8 calibration dataset.txt (same one convert_rknn.py used)")
    ap.add_argument("--platform", default="rk3568", help="quantization target platform")
    ap.add_argument("--conf", type=float, default=0.25, help="confidence threshold")
    ap.add_argument("--iou", type=float, default=0.6, help="NMS IoU threshold")
    ap.add_argument("--max-det", type=int, default=300, help="NMS max detections")
    ap.add_argument("--nms", default="pr_split", choices=["pr_split", "class", "agnostic"],
                    help="NMS mode")
    ap.add_argument("--out-dir", default=DEFAULT_OUT_DIR, help="JSON report directory")
    args = ap.parse_args(argv)

    if args.mode == "auto":
        args.mode = "rgb" if args.rgb else "video"
    if args.board_csv is None:
        ap.error("--board-csv is required")
    if args.video is None:
        ap.error("--video is required")
    if args.stride < 1:
        ap.error("--stride must be >= 1")
    if args.limit < 0:
        ap.error("--limit must be >= 0")
    if args.mode == "rgb":
        if args.rgb is None:
            ap.error("--rgb is required in rgb mode")
        if args.frame is None:
            ap.error("--frame is required in rgb mode")
        if args.frame < 0:
            ap.error("--frame must be >= 0")
    return args


# --------------------------------------------------------------------------
# board CSV
# --------------------------------------------------------------------------

def read_board_csv(path):
    """Return (dets_by_frame, time_ms_by_frame, row_count)."""
    dets = {}
    times = {}
    rows = 0
    with open(path, "r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        try:
            header = [h.strip() for h in next(reader)]
        except StopIteration:
            raise ValueError("board CSV is empty: %s" % path)
        if header != CSV_FIELDS:
            raise ValueError(
                "board CSV header mismatch in %s: got %r, expected %r"
                % (path, header, CSV_FIELDS))
        for lineno, row in enumerate(reader, 2):
            if not row or not row[0].strip():
                continue
            if len(row) != len(CSV_FIELDS):
                raise ValueError("%s:%d: expected %d columns, got %d (%r)"
                                 % (path, lineno, len(CSV_FIELDS), len(row), row))
            frame = int(row[0])
            cls = int(row[2])
            score = float(row[3])
            if cls < 0:            # board writes a -1 placeholder when nothing was found
                dets.setdefault(frame, [])
                times[frame] = int(row[1])
                continue
            box = [float(row[4]), float(row[5]), float(row[6]), float(row[7])]
            dets.setdefault(frame, []).append({"cls": cls, "score": score, "box": box})
            times[frame] = int(row[1])
            rows += 1
    if not dets:
        raise ValueError("no usable rows in board CSV: %s" % path)
    return dets, times, rows


# --------------------------------------------------------------------------
# PC-side preprocessing (mirrors the board's RGA step as closely as possible)
# --------------------------------------------------------------------------

def crop_to_net(frame_bgr):
    """1920x1080 BGR frame -> 960x320 RGB crop (band y in [360,1000))."""
    crop = frame_bgr[CROP_Y:CROP_Y + CROP_H, CROP_X:CROP_X + CROP_W]
    if crop.shape[:2] != (CROP_H, CROP_W):
        raise ValueError("unexpected frame shape %r, board pipeline expects %dx%d"
                         % (crop.shape, CROP_W, CROP_H))
    small = cv2.resize(crop, (NET_W, NET_H), interpolation=cv2.INTER_AREA)
    return cv2.cvtColor(small, cv2.COLOR_BGR2RGB)


def decode_crop(video, indices):
    """Decode the requested frame indices (decode order) and return {idx: RGB crop}."""
    want = sorted(set(int(i) for i in indices))
    if not want:
        return {}
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        raise IOError("cannot open video: %s" % video)
    out = {}
    idx = 0
    try:
        pos = 0
        while pos < len(want):
            if not cap.grab():
                break
            if idx == want[pos]:
                ok, frame = cap.retrieve()
                if not ok:
                    raise IOError("cv2 retrieve failed at frame %d" % idx)
                out[idx] = crop_to_net(frame)
                pos += 1
            idx += 1
    finally:
        cap.release()
    missing = [i for i in want if i not in out]
    if missing:
        raise IOError("could not decode frames %r from %s (decoded up to %d)"
                      % (missing[:10], video, idx))
    return out


def video_info(video):
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        raise IOError("cannot open video: %s" % video)
    try:
        info = {
            "width": int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
            "height": int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
            "fps": round(float(cap.get(cv2.CAP_PROP_FPS)), 3),
            "frame_count": int(cap.get(cv2.CAP_PROP_FRAME_COUNT)),
        }
    finally:
        cap.release()
    return info


# --------------------------------------------------------------------------
# simulator
# --------------------------------------------------------------------------

def build_simulator(onnx_path, calib_path, platform, out_dir, model):
    """Build the INT8 simulator exactly like eval_rknn_sim.py / convert_rknn.py."""
    from rknn.api import RKNN

    dataset_path, items = convert_rknn.parse_dataset(calib_path)
    # write_resolved() writes <dir>/_dataset_resolved.txt next to the given path;
    # keep it inside the report directory so nothing outside it is touched.
    resolved = convert_rknn.write_resolved(
        os.path.join(out_dir, "_calib_%s.rknn" % model), items)

    config_kwargs = {
        "mean_values": [[0, 0, 0]],
        "std_values": [[255, 255, 255]],
        "target_platform": platform,
        "quantized_dtype": "asymmetric_quantized-8",
        "quantized_algorithm": "normal",
        "quantized_method": "channel",
        "optimization_level": 3,
    }
    rknn = RKNN(verbose=False)
    rknn.config(**config_kwargs)
    ret = rknn.load_onnx(model=onnx_path)
    if ret != 0:
        raise RuntimeError("rknn.load_onnx failed with ret=%s" % ret)
    t0 = time.time()
    ret = rknn.build(do_quantization=True, dataset=resolved)
    if ret != 0:
        raise RuntimeError("rknn.build failed with ret=%s" % ret)
    build_s = time.time() - t0
    ret = rknn.init_runtime()
    if ret != 0:
        raise RuntimeError("rknn.init_runtime failed with ret=%s" % ret)
    return rknn, {"dataset": dataset_path, "calib_images": len(items),
                  "build_seconds": round(build_s, 2)}


def map_to_src(box):
    """Network coords (960x320 band) -> 1920x1080 frame coords, clamped like npu_map_to_src."""
    x1 = min(max(box[0] * SCALE_X, 0.0), float(SRC_W - 1))
    y1 = min(max(box[1] * SCALE_Y + CROP_Y, 0.0), float(SRC_H - 1))
    x2 = min(max(box[2] * SCALE_X, 0.0), float(SRC_W - 1))
    y2 = min(max(box[3] * SCALE_Y + CROP_Y, 0.0), float(SRC_H - 1))
    return [x1, y1, x2, y2]


def infer(rknn, meta, rgb, args):
    """Run the simulator on one 960x320x3 RGB crop and return source-frame detections."""
    raw = rknn.inference(inputs=[np.ascontiguousarray(rgb[None])], data_format="nhwc")
    outs = convert_rknn.coerce_outputs(raw, meta["outputs"])
    boxes, scores = rknn_postprocess.dfl_decode(outs, meta["strides"], meta["reg_max"])
    b, s, c = rknn_postprocess.nms(
        boxes, scores, conf_thres=args.conf, iou_thres=args.iou,
        max_det=args.max_det, mode=args.nms)
    dets = []
    for bi, si, ci in zip(b, s, c):
        dets.append({"cls": int(ci), "score": float(si), "box": map_to_src(bi)})
    return dets


# --------------------------------------------------------------------------
# matching and statistics
# --------------------------------------------------------------------------

def iou_xyxy(a, b):
    x1 = max(a[0], b[0])
    y1 = max(a[1], b[1])
    x2 = min(a[2], b[2])
    y2 = min(a[3], b[3])
    iw = max(x2 - x1, 0.0)
    ih = max(y2 - y1, 0.0)
    inter = iw * ih
    area_a = max(a[2] - a[0], 0.0) * max(a[3] - a[1], 0.0)
    area_b = max(b[2] - b[0], 0.0) * max(b[3] - b[1], 0.0)
    union = area_a + area_b - inter
    if union <= 0.0:
        return 0.0
    return inter / union


def match_frame(board_dets, sim_dets, iou_thres=MATCH_IOU):
    """Score-greedy one-to-one matching inside a class with IoU >= iou_thres."""
    order = sorted(range(len(board_dets)), key=lambda i: -board_dets[i]["score"])
    used = [False] * len(sim_dets)
    matches = []
    unmatched_board = []
    for i in order:
        d = board_dets[i]
        best_j = -1
        best_iou = -1.0
        for j, s in enumerate(sim_dets):
            if used[j] or s["cls"] != d["cls"]:
                continue
            v = iou_xyxy(d["box"], s["box"])
            if v > best_iou:
                best_iou = v
                best_j = j
        if best_j >= 0 and best_iou >= iou_thres:
            used[best_j] = True
            matches.append((d, sim_dets[best_j], best_iou))
        else:
            unmatched_board.append(d)
    unmatched_sim = [s for j, s in enumerate(sim_dets) if not used[j]]
    return matches, unmatched_board, unmatched_sim


class Stats(object):
    def __init__(self, names):
        self.names = list(names)
        self.nc = len(self.names)
        self.per_cls = {}
        for c in range(self.nc):
            self.per_cls[c] = {"board": 0, "sim": 0, "matched": 0,
                               "only_board": 0, "only_sim": 0,
                               "iou_sum": 0.0, "ds_sum": 0.0}
        self.board = 0
        self.sim = 0
        self.matched = 0
        self.only_board = 0
        self.only_sim = 0
        self.iou_sum = 0.0
        self.ds_sum = 0.0
        self.frame_rows = []

    def _check_cls(self, c):
        if c < 0 or c >= self.nc:
            raise ValueError("class index %d outside model names (nc=%d)" % (c, self.nc))
        return self.per_cls[c]

    def add_frame(self, frame, board_dets, sim_dets, iou_thres=MATCH_IOU):
        matches, only_b, only_s = match_frame(board_dets, sim_dets, iou_thres)
        for d in board_dets:
            self._check_cls(d["cls"])["board"] += 1
        for d in sim_dets:
            self._check_cls(d["cls"])["sim"] += 1
        self.board += len(board_dets)
        self.sim += len(sim_dets)
        self.matched += len(matches)
        self.only_board += len(only_b)
        self.only_sim += len(only_s)
        for d in only_b:
            pc = self._check_cls(d["cls"])
            pc["only_board"] += 1
        for d in only_s:
            pc = self._check_cls(d["cls"])
            pc["only_sim"] += 1
        iou_frame = 0.0
        for d, s, v in matches:
            pc = self._check_cls(d["cls"])
            pc["matched"] += 1
            pc["iou_sum"] += v
            pc["ds_sum"] += abs(d["score"] - s["score"])
            self.iou_sum += v
            self.ds_sum += abs(d["score"] - s["score"])
            iou_frame += v
        row = {
            "frame": int(frame),
            "board": len(board_dets),
            "sim": len(sim_dets),
            "matched": len(matches),
            "only_board": len(only_b),
            "only_sim": len(only_s),
            "mean_iou": round(iou_frame / len(matches), 4) if matches else None,
        }
        self.frame_rows.append(row)
        return row

    def mean_iou(self):
        return self.iou_sum / self.matched if self.matched else None

    def mean_ds(self):
        return self.ds_sum / self.matched if self.matched else None

    def summary(self):
        return {
            "board_boxes": self.board,
            "sim_boxes": self.sim,
            "matched": self.matched,
            "only_board": self.only_board,
            "only_sim": self.only_sim,
            "mean_iou": round(self.mean_iou(), 4) if self.matched else None,
            "mean_abs_score_diff": round(self.mean_ds(), 5) if self.matched else None,
            "board_match_rate": round(
                float(self.matched) / self.board, 5) if self.board else None,
        }

    def per_class_rows(self):
        rows = []
        for c in range(self.nc):
            pc = self.per_cls[c]
            if not (pc["board"] or pc["sim"]):
                continue
            rows.append({
                "cls": c,
                "name": self.names[c] if c < len(self.names) else "cls%d" % c,
                "board": pc["board"],
                "sim": pc["sim"],
                "matched": pc["matched"],
                "only_board": pc["only_board"],
                "only_sim": pc["only_sim"],
                "mean_iou": round(pc["iou_sum"] / pc["matched"], 4) if pc["matched"] else None,
                "mean_abs_score_diff": round(pc["ds_sum"] / pc["matched"], 5)
                if pc["matched"] else None,
            })
        return rows

    def worst_frames(self, n=10):
        rows = sorted(self.frame_rows,
                      key=lambda r: (-(r["only_board"] + r["only_sim"]), r["frame"]))
        return rows[:n]


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

def print_totals(stats, indent="  "):
    s = stats.summary()
    log("%sboard boxes    : %d" % (indent, s["board_boxes"]))
    log("%ssim boxes      : %d" % (indent, s["sim_boxes"]))
    log("%smatched        : %d" % (indent, s["matched"]))
    log("%sonly board     : %d" % (indent, s["only_board"]))
    log("%sonly sim       : %d" % (indent, s["only_sim"]))
    if s["mean_iou"] is not None:
        log("%smean IoU       : %.4f" % (indent, s["mean_iou"]))
        log("%smean |dscore|  : %.5f" % (indent, s["mean_abs_score_diff"]))
        log("%sboard matched  : %.2f%%" % (indent, 100.0 * s["board_match_rate"]))
    else:
        log("%smean IoU       : n/a (no matched box)" % indent)


def print_per_class(stats, indent="  "):
    rows = stats.per_class_rows()
    if not rows:
        log("%s(no detections at all)" % indent)
        return
    hdr = "%-4s %-12s %6s %6s %7s %7s %7s %8s %10s" % (
        "cls", "name", "board", "sim", "matched", "only_b", "only_s", "meanIoU", "mean|ds|")
    log("%s%s" % (indent, hdr))
    for r in rows:
        log("%s%-4d %-12s %6d %6d %7d %7d %7d %8s %10s" % (
            indent, r["cls"], r["name"], r["board"], r["sim"], r["matched"],
            r["only_board"], r["only_sim"],
            "%.4f" % r["mean_iou"] if r["mean_iou"] is not None else "-",
            "%.5f" % r["mean_abs_score_diff"] if r["mean_abs_score_diff"] is not None else "-"))


def print_worst(stats, n=10, indent="  "):
    rows = stats.worst_frames(n)
    if not rows:
        return
    log("%s%-7s %6s %6s %8s %7s %7s" % (indent, "frame", "board", "sim",
                                        "matched", "only_b", "only_s"))
    for r in rows:
        log("%s%-7d %6d %6d %8d %7d %7d" % (
            indent, r["frame"], r["board"], r["sim"], r["matched"],
            r["only_board"], r["only_sim"]))


def write_json(out_dir, mode, model, payload):
    os.makedirs(out_dir, exist_ok=True)
    name = "compare_%s_%s_%s.json" % (mode, model, time.strftime("%Y%m%d_%H%M%S"))
    path = os.path.join(out_dir, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
    return path


# --------------------------------------------------------------------------
# modes
# --------------------------------------------------------------------------

def run_video(args):
    csv_path = resolve(args.board_csv)
    video = resolve(args.video)
    onnx_path = resolve(MODELS[args.model])
    calib_path = resolve(args.calib)
    out_dir = resolve(args.out_dir)

    started = time.time()
    log("========== compare_board_sim | video ==========")
    log("model          : %s" % args.model)
    log("onnx           : %s" % onnx_path)
    log("board csv      : %s" % csv_path)
    log("video          : %s" % video)

    meta = convert_rknn.load_meta(onnx_path)
    vinfo = video_info(video)
    log("video info     : %dx%d, fps=%s, frames=%d"
        % (vinfo["width"], vinfo["height"], vinfo["fps"], vinfo["frame_count"]))
    if vinfo["height"] != SRC_H and vinfo["width"] != SRC_W:
        raise ValueError("video is %dx%d, the board pipeline assumes %dx%d"
                         % (vinfo["width"], vinfo["height"], SRC_W, SRC_H))

    board_dets, board_times, rows = read_board_csv(csv_path)
    board_frames = sorted(board_dets)
    if vinfo["frame_count"] > 0 and board_frames[-1] >= vinfo["frame_count"]:
        raise ValueError(
            "board CSV references frame %d but the video only has %d frames; "
            "frame numbering does not line up" % (board_frames[-1], vinfo["frame_count"]))
    log("board csv      : %d rows, %d frames (frame %d..%d)"
        % (rows, len(board_frames), board_frames[0], board_frames[-1]))

    selected = board_frames[::args.stride]
    if args.limit:
        selected = selected[:args.limit]
    if not selected:
        raise ValueError("no frame selected (stride=%d limit=%d)" % (args.stride, args.limit))
    log("selected       : %d frames (stride=%d, limit=%d)"
        % (len(selected), args.stride, args.limit))
    log("postprocess    : conf=%.2f iou=%.2f nms=%s max_det=%d"
        % (args.conf, args.iou, args.nms, args.max_det))

    log("building INT8 simulator from ONNX (quantization, ~30-60 s)...")
    rknn, build_info = build_simulator(onnx_path, calib_path, args.platform,
                                       out_dir, args.model)
    log("sim build      : %.1f s (%d calib images)"
        % (build_info["build_seconds"], build_info["calib_images"]))

    stats = Stats(meta["names"])
    infer_times = []
    try:
        crops = decode_crop(video, selected)
        # Warm up the simulator graph so the first-frame overhead is reported separately.
        t0 = time.time()
        infer(rknn, meta, crops[selected[0]], args)
        warmup_s = time.time() - t0
        log("sim warmup     : %.2f s" % warmup_s)

        n = 0
        for frame in selected:
            rgb = crops.pop(frame)
            t0 = time.time()
            sim_dets = infer(rknn, meta, rgb, args)
            infer_times.append(time.time() - t0)
            bd = board_dets.get(frame, [])
            row = stats.add_frame(frame, bd, sim_dets)
            n += 1
            if n % 10 == 0 or n == len(selected):
                log("  %d/%d frames done (last frame %d: board=%d sim=%d matched=%d)"
                    % (n, len(selected), frame, row["board"], row["sim"], row["matched"]))
    finally:
        try:
            rknn.release()
        except Exception:
            pass

    dur = sum(infer_times)
    avg = dur / len(infer_times) if infer_times else 0.0
    log("sim inference  : %d frames, %.2f s total, %.3f s/frame"
        % (len(infer_times), dur, avg))
    log("---- totals ----")
    print_totals(stats)
    log("---- per class ----")
    print_per_class(stats)
    log("---- worst 10 frames (only_board + only_sim) ----")
    print_worst(stats)

    est_full = build_info["build_seconds"] + avg * len(board_frames)
    log("est. full run  : %d frames -> %.1f s (build + inference)"
        % (len(board_frames), est_full))

    payload = {
        "mode": "video",
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "model": args.model,
        "onnx": onnx_path,
        "board_csv": csv_path,
        "video": video,
        "video_info": vinfo,
        "board": {"rows": rows, "frames": len(board_frames),
                  "frame_min": board_frames[0], "frame_max": board_frames[-1]},
        "selection": {"stride": args.stride, "limit": args.limit,
                      "frames": len(selected)},
        "preprocess": {
            "crop": {"x": CROP_X, "y": CROP_Y, "w": CROP_W, "h": CROP_H},
            "resize": [NET_W, NET_H], "interpolation": "INTER_AREA",
            "color": "RGB", "range": "limited (source NV12 BT601 limited, PC uses full-range BGR)"},
        "postprocess": {"conf": args.conf, "iou": args.iou, "nms": args.nms,
                        "max_det": args.max_det,
                        "map_to_src": "x*%.1f, y*%.1f+%d, clamped to [0,%d]x[0,%d]"
                                      % (SCALE_X, SCALE_Y, CROP_Y, SRC_W - 1, SRC_H - 1)},
        "match": {"iou_thres": MATCH_IOU, "strategy": "score-greedy, same class, one-to-one"},
        "sim_build": build_info,
        "timing": {"warmup_seconds": round(warmup_s, 2),
                   "infer_seconds": round(dur, 2),
                   "infer_seconds_per_frame": round(avg, 4),
                   "total_seconds": round(time.time() - started, 2),
                   "est_full_run_seconds": round(est_full, 1)},
        "summary": stats.summary(),
        "per_class": stats.per_class_rows(),
        "frames": stats.frame_rows,
        "worst_frames": stats.worst_frames(10),
    }
    path = write_json(out_dir, "video", args.model, payload)
    log("JSON           : %s" % path)
    log("========== done in %.1f s ==========" % (time.time() - started))
    return 0, payload


def load_rgb_dump(path):
    buf = np.fromfile(path, dtype=np.uint8)
    expect = NET_W * NET_H * 3
    if buf.size != expect:
        raise ValueError("rgb dump %s has %d bytes, expected %d (=%dx%dx3 raw RGB)"
                         % (path, buf.size, expect, NET_W, NET_H))
    return buf.reshape(NET_H, NET_W, 3)


def channel_compare(a, b):
    """Per-channel mean absolute difference, max abs difference and PSNR (dB)."""
    d = np.abs(a.astype(np.int32) - b.astype(np.int32))
    out = {"mae": [], "max": [], "psnr": []}
    for c in range(3):
        dc = d[:, :, c]
        mae = float(dc.mean())
        mse = float((dc.astype(np.float64) ** 2).mean())
        out["mae"].append(round(mae, 3))
        out["max"].append(int(dc.max()))
        out["psnr"].append(round(10.0 * np.log10(255.0 * 255.0 / mse), 2) if mse > 0 else None)
    return out


def run_rgb(args):
    csv_path = resolve(args.board_csv)
    video = resolve(args.video)
    onnx_path = resolve(MODELS[args.model])
    calib_path = resolve(args.calib)
    dump_path = resolve(args.rgb)
    out_dir = resolve(args.out_dir)

    started = time.time()
    log("========== compare_board_sim | rgb ==========")
    log("model          : %s" % args.model)
    log("board csv      : %s" % csv_path)
    log("video          : %s" % video)
    log("rgb dump       : %s" % dump_path)
    log("board frame    : %d" % args.frame)

    meta = convert_rknn.load_meta(onnx_path)
    vinfo = video_info(video)
    board_dets, board_times, rows = read_board_csv(csv_path)
    if args.frame not in board_dets:
        raise ValueError("frame %d is not present in %s" % (args.frame, csv_path))
    dump = load_rgb_dump(dump_path)
    log("dump loaded    : %dx%dx3 uint8" % (dump.shape[1], dump.shape[0]))
    if args.frame >= vinfo["frame_count"]:
        raise ValueError("frame %d >= video frame count %d"
                         % (args.frame, vinfo["frame_count"]))

    # 1) frame alignment: compare the dump against PC crops of frames N-2..N+2
    offsets = [-2, -1, 0, 1, 2]
    cand = [args.frame + o for o in offsets if 0 <= args.frame + o < vinfo["frame_count"]]
    crops = decode_crop(video, cand)
    log("---- dump vs PC crops (per channel R/G/B) ----")
    log("  %-7s %-26s %-18s %-22s" % ("frame", "MAE R/G/B", "max R/G/B", "PSNR R/G/B dB"))
    align_rows = []
    for f in cand:
        cmp = channel_compare(dump, crops[f])
        align_rows.append({"frame": f, "offset": f - args.frame,
                           "mae": cmp["mae"], "max": cmp["max"], "psnr": cmp["psnr"]})
        log("  %-7d %-26s %-18s %-22s" % (
            f,
            "%.2f/%.2f/%.2f" % tuple(cmp["mae"]),
            "%d/%d/%d" % tuple(cmp["max"]),
            "/".join("-" if p is None else "%.2f" % p for p in cmp["psnr"])))
    best = min(align_rows, key=lambda r: sum(r["mae"]))
    log("  closest PC frame: %d (offset %+d, mean MAE %.3f)"
        % (best["frame"], best["offset"], sum(best["mae"]) / 3.0))
    if best["offset"] != 0:
        log("  WARNING: dump aligns with frame %d, not the requested frame %d"
            % (best["frame"], args.frame))

    # 2) run the simulator on the dump and match against the board boxes of frame N
    log("building INT8 simulator from ONNX (quantization, ~30-60 s)...")
    rknn, build_info = build_simulator(onnx_path, calib_path, args.platform,
                                       out_dir, args.model)
    log("sim build      : %.1f s (%d calib images)"
        % (build_info["build_seconds"], build_info["calib_images"]))
    try:
        t0 = time.time()
        infer(rknn, meta, dump, args)   # warmup
        warmup_s = time.time() - t0
        t0 = time.time()
        sim_dets = infer(rknn, meta, dump, args)
        infer_s = time.time() - t0
    finally:
        try:
            rknn.release()
        except Exception:
            pass
    log("sim warmup     : %.2f s, dump inference: %.3f s" % (warmup_s, infer_s))

    stats = Stats(meta["names"])
    stats.add_frame(args.frame, board_dets[args.frame], sim_dets)
    matches, only_b, only_s = match_frame(board_dets[args.frame], sim_dets)
    log("---- totals (frame %d) ----" % args.frame)
    print_totals(stats)
    log("---- per class ----")
    print_per_class(stats)

    payload = {
        "mode": "rgb",
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "model": args.model,
        "onnx": onnx_path,
        "board_csv": csv_path,
        "video": video,
        "video_info": vinfo,
        "rgb": dump_path,
        "frame": args.frame,
        "preprocess": {
            "crop": {"x": CROP_X, "y": CROP_Y, "w": CROP_W, "h": CROP_H},
            "resize": [NET_W, NET_H], "interpolation": "INTER_AREA",
            "color": "RGB",
        },
        "postprocess": {"conf": args.conf, "iou": args.iou, "nms": args.nms,
                        "max_det": args.max_det,
                        "map_to_src": "x*%.1f, y*%.1f+%d, clamped to [0,%d]x[0,%d]"
                                      % (SCALE_X, SCALE_Y, CROP_Y, SRC_W - 1, SRC_H - 1)},
        "match": {"iou_thres": MATCH_IOU, "strategy": "score-greedy, same class, one-to-one"},
        "alignment": {"offsets": offsets, "candidates": align_rows,
                      "closest_frame": best["frame"], "closest_offset": best["offset"],
                      "closest_mean_mae": round(sum(best["mae"]) / 3.0, 3)},
        "sim_build": build_info,
        "timing": {"warmup_seconds": round(warmup_s, 2),
                   "infer_seconds": round(infer_s, 3),
                   "total_seconds": round(time.time() - started, 2)},
        "board_dets": board_dets[args.frame],
        "sim_dets": [{"cls": d["cls"], "score": round(d["score"], 5),
                      "box": [round(v, 2) for v in d["box"]]} for d in sim_dets],
        "matches": [{"board": {"cls": d["cls"], "score": round(d["score"], 5),
                               "box": [round(v, 2) for v in d["box"]]},
                     "sim": {"cls": s["cls"], "score": round(s["score"], 5),
                             "box": [round(v, 2) for v in s["box"]]},
                     "iou": round(v, 4)} for d, s, v in matches],
        "only_board": [{"cls": d["cls"], "score": round(d["score"], 5),
                        "box": [round(v, 2) for v in d["box"]]} for d in only_b],
        "only_sim": [{"cls": d["cls"], "score": round(d["score"], 5),
                      "box": [round(v, 2) for v in d["box"]]} for d in only_s],
        "summary": stats.summary(),
        "per_class": stats.per_class_rows(),
    }
    path = write_json(out_dir, "rgb", args.model, payload)
    log("JSON           : %s" % path)
    log("========== done in %.1f s ==========" % (time.time() - started))
    return 0, payload


def main(argv=None):
    args = parse_args(argv)
    if args.mode == "rgb":
        return run_rgb(args)[0]
    return run_video(args)[0]


if __name__ == "__main__":
    sys.exit(main())
