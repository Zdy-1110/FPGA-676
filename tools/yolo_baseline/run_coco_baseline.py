import argparse
import csv
import json
import os
import subprocess
import sys
import time
from pathlib import Path

YOLO_CFG_DIR = r"E:\Project\nesai2026\.yolo_cfg"
os.makedirs(YOLO_CFG_DIR, exist_ok=True)
os.environ.setdefault("YOLO_CONFIG_DIR", YOLO_CFG_DIR)
os.environ["YOLO_OFFLINE"] = "True"

import cv2
import numpy as np
from ultralytics import YOLO, settings

settings.update({"sync": False})

COCO_CLASSES = {
    0: "person",
    1: "bicycle",
    2: "car",
    3: "motorcycle",
    5: "bus",
    7: "truck",
    9: "traffic light",
    11: "stop sign",
}
PROJ_CLASS = {
    0: "person",
    1: "rider",
    2: "car",
    3: "rider",
    5: "bus",
    7: "truck",
    9: "tl_ref",
    11: "other_ref",
}
PROJ_CLASSES = ["person", "rider", "car", "bus", "truck", "tl_ref", "other_ref"]
COLORS = {
    "person": (0, 0, 255),
    "rider": (0, 165, 255),
    "car": (255, 128, 0),
    "bus": (255, 0, 255),
    "truck": (0, 255, 255),
    "tl_ref": (0, 255, 0),
    "other_ref": (200, 200, 200),
}
HIST_BUCKETS = ["<8", "8-16", "16-32", "32-64", ">=64"]


def build_parser():
    p = argparse.ArgumentParser(description="COCO yolo11n baseline on a road video")
    p.add_argument("--video", required=True)
    p.add_argument("--weights", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--imgsz", type=int, default=640)
    p.add_argument("--conf", type=float, default=0.25)
    p.add_argument("--iou", type=float, default=0.7)
    p.add_argument("--device", default="cpu")
    p.add_argument("--fps", type=float, default=30.0)
    p.add_argument("--width", type=int, default=1920)
    p.add_argument("--height", type=int, default=1080)
    p.add_argument("--ffmpeg", default=r"D:\Program Files\FormatFactory\ffmpeg.exe")
    p.add_argument("--max-frames", type=int, default=0)
    p.add_argument("--snap-every", type=float, default=2.0)
    p.add_argument("--only-snaps", action="store_true")
    p.add_argument("--crf", type=int, default=23)
    return p


def hist_bucket(h640):
    if h640 < 8:
        return "<8"
    if h640 < 16:
        return "8-16"
    if h640 < 32:
        return "16-32"
    if h640 < 64:
        return "32-64"
    return ">=64"


def overlap_width(a, b):
    return max(0.0, min(a["x2"], b["x2"]) - max(a["x1"], b["x1"]))


def merge_detections(dets):
    persons = [d for d in dets if d["coco_id"] == 0]
    two_wheelers = [d for d in dets if d["coco_id"] in (1, 3)]
    assigned = {id(m): [] for m in two_wheelers}
    free_persons = []
    for p in persons:
        pw = p["x2"] - p["x1"]
        pcy = (p["y1"] + p["y2"]) / 2.0
        best = None
        best_ov = -1.0
        for m in two_wheelers:
            ov = overlap_width(p, m)
            mcy = (m["y1"] + m["y2"]) / 2.0
            if ov >= 0.5 * pw and pcy < mcy and p["y2"] >= m["y1"] and ov > best_ov:
                best = m
                best_ov = ov
        if best is None:
            free_persons.append(p)
        else:
            assigned[id(best)].append(p)

    merged = []
    for m in two_wheelers:
        group = assigned[id(m)]
        if group:
            x1 = min([m["x1"]] + [p["x1"] for p in group])
            y1 = min([m["y1"]] + [p["y1"] for p in group])
            x2 = max([m["x2"]] + [p["x2"] for p in group])
            y2 = max([m["y2"]] + [p["y2"] for p in group])
            conf = max([m["conf"]] + [p["conf"] for p in group])
            merged.append({
                "proj_cls": "rider", "src": "merged", "conf": conf,
                "x1": x1, "y1": y1, "x2": x2, "y2": y2,
            })
        else:
            merged.append({
                "proj_cls": "rider", "src": "2w_only", "conf": m["conf"],
                "x1": m["x1"], "y1": m["y1"], "x2": m["x2"], "y2": m["y2"],
            })
    for p in free_persons:
        merged.append({
            "proj_cls": "person", "src": "coco_person", "conf": p["conf"],
            "x1": p["x1"], "y1": p["y1"], "x2": p["x2"], "y2": p["y2"],
        })
    for d in dets:
        if d["coco_id"] in (0, 1, 3):
            continue
        merged.append({
            "proj_cls": PROJ_CLASS[d["coco_id"]],
            "src": "coco_" + d["coco_name"].replace(" ", "_"),
            "conf": d["conf"],
            "x1": d["x1"], "y1": d["y1"], "x2": d["x2"], "y2": d["y2"],
        })
    return merged

def draw_frame(frame, merged, frame_idx, t, infer_ms, args, video_stem):
    vis = frame.copy()
    counts = {"person": 0, "rider": 0, "car": 0, "bus": 0, "truck": 0, "tl_ref": 0}
    for d in merged:
        color = COLORS.get(d["proj_cls"], (255, 255, 255))
        x1, y1, x2, y2 = int(d["x1"]), int(d["y1"]), int(d["x2"]), int(d["y2"])
        cv2.rectangle(vis, (x1, y1), (x2, y2), color, 3)
        label = f"{d['proj_cls']} {d['conf']:.2f}"
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.8, 2)
        if y1 >= 30:
            by = y1 - 6
        else:
            by = y1 + th + 8
        ty = max(by - 2, th + 2)
        cv2.rectangle(vis, (x1, ty - th - 4), (x1 + tw + 4, ty + 4), color, -1)
        cv2.putText(vis, label, (x1 + 2, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.8,
                    (0, 0, 0), 2, cv2.LINE_AA)
        if d["proj_cls"] in counts:
            counts[d["proj_cls"]] += 1

    weights_stem = Path(args.weights).stem
    line1 = f"{video_stem}  t={t:.1f}s  f={frame_idx}"
    line2 = (f"COCO {weights_stem} imgsz={args.imgsz} conf={args.conf:g} "
             f"(PC baseline, not on-board)")
    line3 = (f"person {counts['person']}  rider {counts['rider']}  car {counts['car']}  "
             f"bus {counts['bus']}  truck {counts['truck']}  tl {counts['tl_ref']}")
    line4 = f"infer {infer_ms:.1f} ms"
    lines = [line1, line2, line3, line4]
    font = cv2.FONT_HERSHEY_SIMPLEX
    widths = [cv2.getTextSize(s, font, 0.9, 2)[0][0] for s in lines]
    line_h = 34
    box_w = max(widths) + 24
    box_h = line_h * len(lines) + 16
    overlay = vis.copy()
    cv2.rectangle(overlay, (8, 8), (8 + box_w, 8 + box_h), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.55, vis, 0.45, 0, vis)
    for k, s in enumerate(lines):
        y = 8 + 16 + (k + 1) * line_h - 8
        cv2.putText(vis, s, (18, y), font, 0.9, (255, 255, 255), 2, cv2.LINE_AA)
    return vis


def main():
    args = build_parser().parse_args()
    video = Path(args.video)
    weights = Path(args.weights)
    if not video.is_file():
        print(f"[error] video not found: {video}", file=sys.stderr)
        return 2
    if not weights.is_file():
        print(f"[error] weights not found: {weights}", file=sys.stderr)
        return 2

    out_dir = Path(args.out_dir)
    snaps_dir = out_dir / "snaps"
    out_dir.mkdir(parents=True, exist_ok=True)
    snaps_dir.mkdir(parents=True, exist_ok=True)
    video_stem = video.stem
    w, h = args.width, args.height
    frame_bytes = w * h * 3

    model = YOLO(str(weights))
    snap_step = round(args.snap_every * args.fps) if args.snap_every > 0 else 0

    writer = None
    if not args.only_snaps:
        out_mp4 = out_dir / f"{video_stem}_det.mp4"
        writer_cmd = [
            args.ffmpeg, "-v", "error", "-y", "-f", "rawvideo",
            "-pix_fmt", "bgr24", "-s", f"{w}x{h}", "-r", str(args.fps), "-i", "-",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", str(args.crf),
            "-pix_fmt", "yuv420p", str(out_mp4),
        ]
        writer = subprocess.Popen(writer_cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)

    dec_cmd = [
        args.ffmpeg, "-v", "error", "-i", str(video),
        "-f", "rawvideo", "-pix_fmt", "bgr24", "-",
    ]
    dec = subprocess.Popen(dec_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    raw_rows = []
    det_rows = []
    raw_counts = {name: 0 for name in COCO_CLASSES.values()}
    class_boxes = {c: 0 for c in PROJ_CLASSES}
    class_frames = {c: set() for c in PROJ_CLASSES}
    class_hist = {c: {b: 0 for b in HIST_BUCKETS} for c in PROJ_CLASSES}
    infer_ms = []
    snap_frames = []
    frames_total = 0
    frames_inferred = 0
    early_stop = False
    t_start = time.perf_counter()

    i = 0
    while True:
        if args.max_frames > 0 and i >= args.max_frames:
            early_stop = True
            break
        buf = dec.stdout.read(frame_bytes)
        if len(buf) < frame_bytes:
            break
        frame = np.frombuffer(buf, dtype=np.uint8).reshape((h, w, 3)).copy()
        t = i / args.fps
        frames_total += 1
        is_snap = snap_step > 0 and (i % snap_step == 0)

        dets = []
        ms = 0.0
        if (not args.only_snaps) or is_snap:
            t0 = time.perf_counter()
            r = model.predict(frame, imgsz=args.imgsz, conf=args.conf, iou=args.iou,
                              device=args.device, classes=[0, 1, 2, 3, 5, 7, 9, 11],
                              verbose=False)[0]
            ms = (time.perf_counter() - t0) * 1000.0
            infer_ms.append(ms)
            frames_inferred += 1
            for b in r.boxes:
                cid = int(b.cls.item())
                cf = float(b.conf.item())
                x1, y1, x2, y2 = [float(v) for v in b.xyxy[0].tolist()]
                cname = COCO_CLASSES.get(cid)
                if cname is None:
                    continue
                dets.append({"coco_id": cid, "coco_name": cname, "conf": cf,
                             "x1": x1, "y1": y1, "x2": x2, "y2": y2})
                raw_rows.append([i, t, cid, cname, cf, x1, y1, x2, y2])
                raw_counts[cname] += 1

        if is_snap:
            snap_frames.append(i)

        vis = None
        if (not args.only_snaps) or is_snap:
            merged = merge_detections(dets)
            frame_classes = set()
            for d in merged:
                h640 = (d["y2"] - d["y1"]) * 640.0 / w
                det_rows.append([i, t, d["proj_cls"], d["src"], d["conf"],
                                 d["x1"], d["y1"], d["x2"], d["y2"], h640])
                c = d["proj_cls"]
                class_boxes[c] += 1
                frame_classes.add(c)
                class_hist[c][hist_bucket(h640)] += 1
            for c in frame_classes:
                class_frames[c].add(i)
            vis = draw_frame(frame, merged, i, t, ms, args, video_stem)

        if is_snap:
            t_name = f"{t:05.1f}"
            cv2.imwrite(str(snaps_dir / f"{video_stem}_t{t_name}_det.jpg"), vis,
                        [cv2.IMWRITE_JPEG_QUALITY, 90])
            cv2.imwrite(str(snaps_dir / f"{video_stem}_t{t_name}_raw.jpg"), frame,
                        [cv2.IMWRITE_JPEG_QUALITY, 85])

        if writer is not None and vis is not None:
            writer.stdin.write(vis.tobytes())

        if i % 300 == 0:
            elapsed = time.perf_counter() - t_start
            avg_fps = (i + 1) / elapsed if elapsed > 0 else 0.0
            print(f"[progress] frame={i} t={t:.1f}s avg={avg_fps:.1f} fps", flush=True)
        i += 1

    dec.stdout.close()
    if early_stop:
        dec.terminate()
        dec.wait()
        dec_rc = 0
    else:
        dec_rc = dec.wait()
    if dec_rc != 0:
        err = dec.stderr.read().decode("utf-8", errors="replace")
        print(f"[error] decode ffmpeg rc={dec_rc}\n{err}", file=sys.stderr)
        if writer is not None:
            writer.stdin.close()
            writer.wait()
        return 3

    if writer is not None:
        try:
            writer.stdin.close()
        except Exception:
            pass
        w_rc = writer.wait()
        if w_rc != 0:
            err = writer.stderr.read().decode("utf-8", errors="replace")
            print(f"[error] encode ffmpeg rc={w_rc}\n{err}", file=sys.stderr)
            return 3

    with open(out_dir / "raw_detections.csv", "w", newline="", encoding="utf-8") as f:
        cw = csv.writer(f)
        cw.writerow(["frame", "t", "coco_id", "coco_name", "conf", "x1", "y1", "x2", "y2"])
        for r in raw_rows:
            cw.writerow([r[0], f"{r[1]:.3f}", r[2], r[3], f"{r[4]:.4f}",
                         f"{r[5]:.1f}", f"{r[6]:.1f}", f"{r[7]:.1f}", f"{r[8]:.1f}"])

    with open(out_dir / "detections.csv", "w", newline="", encoding="utf-8") as f:
        cw = csv.writer(f)
        cw.writerow(["frame", "t", "proj_cls", "src", "conf",
                     "x1", "y1", "x2", "y2", "h640"])
        for r in det_rows:
            cw.writerow([r[0], f"{r[1]:.3f}", r[2], r[3], f"{r[4]:.4f}",
                         f"{r[5]:.1f}", f"{r[6]:.1f}", f"{r[7]:.1f}",
                         f"{r[8]:.1f}", f"{r[9]:.1f}"])

    if infer_ms:
        s = sorted(infer_ms)
        idx = max(0, int(np.ceil(0.95 * len(s))) - 1)
        mean_ms = sum(s) / len(s)
        p95_ms = s[idx]
    else:
        mean_ms = 0.0
        p95_ms = 0.0

    classes = {}
    for c in PROJ_CLASSES:
        classes[c] = {
            "boxes": class_boxes[c],
            "frames_with": len(class_frames[c]),
            "mean_per_frame": round(class_boxes[c] / frames_inferred, 4) if frames_inferred else 0.0,
            "h640_hist": class_hist[c],
        }

    summary = {
        "video": str(video),
        "weights": str(weights),
        "imgsz": args.imgsz,
        "conf": args.conf,
        "iou": args.iou,
        "device": args.device,
        "fps": args.fps,
        "width": w,
        "height": h,
        "frames_total": frames_total,
        "frames_inferred": frames_inferred,
        "snap_frames": snap_frames,
        "infer_ms_mean": round(mean_ms, 3),
        "infer_ms_p95": round(p95_ms, 3),
        "classes": classes,
        "raw_coco_counts": raw_counts,
    }
    with open(out_dir / "summary.json", "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)

    print(f"[done] frames_total={frames_total} frames_inferred={frames_inferred} "
          f"mean={summary['infer_ms_mean']}ms p95={summary['infer_ms_p95']}ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())

