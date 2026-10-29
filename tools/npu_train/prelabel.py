"""COCO-pretrained YOLOv8 pre-labeling for the NPU road-band dataset."""

import argparse
import csv
import glob
import os
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import npu_common as nc

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if not os.environ.get("YOLO_CONFIG_DIR"):
    os.environ["YOLO_CONFIG_DIR"] = os.path.join(PROJECT_ROOT, ".yolo_cfg")

from ultralytics import YOLO

COCO_CLASSES = [0, 1, 2, 3, 5, 7]
CLASS_COLORS = [
    (0, 0, 255), (0, 165, 255), (255, 128, 0), (255, 0, 255), (0, 255, 255),
    (255, 255, 0), (128, 0, 255), (0, 128, 255), (255, 0, 0),
]


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--pool", required=True)
    p.add_argument("--exclude", nargs="*", default=[])
    p.add_argument("--weights", required=True)
    p.add_argument("--imgsz", type=int, default=1280)
    p.add_argument("--conf", type=float, default=0.25)
    p.add_argument("--iou", type=float, default=0.6)
    p.add_argument("--device", default="0")
    p.add_argument("--out", required=True)
    p.add_argument("--preview-per-video", type=int, default=2)
    p.add_argument("--batch", type=int, default=1)
    p.add_argument("--threads", type=int, default=0)
    p.add_argument("--skip-existing", action="store_true")
    return p.parse_args()


def label_color(cls):
    return CLASS_COLORS[cls % len(CLASS_COLORS)]


def draw_preview(img, boxes, path, video_name, img_name):
    vis = img.copy()
    cv2.line(vis, (0, nc.BAND_Y0), (vis.shape[1], nc.BAND_Y0), (0, 255, 0), 3)
    cv2.line(vis, (0, nc.BAND_Y1), (vis.shape[1], nc.BAND_Y1), (0, 255, 0), 3)
    for d in boxes:
        color = label_color(d["cls"])
        x1, y1 = int(round(d["x1"])), int(round(d["y1"]))
        x2, y2 = int(round(d["x2"])), int(round(d["y2"]))
        cv2.rectangle(vis, (x1, y1), (x2, y2), color, 3)
        if d.get("conf") is None:
            label = nc.CLASS_NAMES[d["cls"]]
        else:
            label = "%s %.2f" % (nc.CLASS_NAMES[d["cls"]], d["conf"])
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.8, 2)
        by = y1 - 6 if y1 >= 30 else y1 + th + 8
        ty = max(by - 2, th + 2)
        cv2.rectangle(vis, (x1, ty - th - 4), (x1 + tw + 4, ty + 4), color, -1)
        cv2.putText(vis, label, (x1 + 2, ty - 2), cv2.FONT_HERSHEY_SIMPLEX,
                    0.8, (0, 0, 0), 2, cv2.LINE_AA)
    cv2.putText(vis, "%s / %s" % (video_name, img_name),
                (20, nc.BAND_Y0 - 20), cv2.FONT_HERSHEY_SIMPLEX, 1.0,
                (0, 255, 0), 2, cv2.LINE_AA)
    nc.imwrite_any(path, vis)


def main():
    args = parse_args()
    t_start = time.time()

    pool = os.path.abspath(args.pool)
    out_root = os.path.abspath(args.out)
    preview_dir = os.path.join(out_root, "_preview")
    os.makedirs(out_root, exist_ok=True)
    os.makedirs(preview_dir, exist_ok=True)

    excludes = set(args.exclude)
    videos = []
    for name in sorted(os.listdir(pool)):
        sub = os.path.join(pool, name)
        if not os.path.isdir(sub) or name in excludes:
            continue
        imgs = sorted(glob.glob(os.path.join(sub, "*.jpg")))
        if imgs:
            videos.append((name, imgs))

    with open(os.path.join(out_root, "classes.txt"), "w",
              encoding="utf-8", newline="\n") as f:
        for name in nc.CLASS_NAMES:
            f.write(name + "\n")

    if args.threads > 0:
        import torch
        torch.set_num_threads(args.threads)
        print("torch threads: %d" % args.threads, flush=True)

    model = YOLO(args.weights)
    print("model loaded: %s" % args.weights, flush=True)

    rows = []
    total_imgs = 0
    total_boxes = 0
    infer_done = 0
    for vname, imgs in videos:
        counts = [0] * len(nc.CLASS_NAMES)
        vbox = 0
        cached = {}
        todo = []
        for img_path in imgs:
            ap = os.path.abspath(img_path)
            stem = os.path.splitext(os.path.basename(ap))[0]
            txt_path = os.path.join(out_root, vname, stem + ".txt")
            if args.skip_existing and os.path.isfile(txt_path):
                boxes = nc.read_yolo_txt(txt_path, nc.SRC_W, nc.SRC_H)
                cached[ap] = [{"cls": int(c), "conf": None, "x1": x1, "y1": y1,
                               "x2": x2, "y2": y2}
                              for c, x1, y1, x2, y2 in boxes]
            else:
                todo.append(ap)
        inferred = {}
        v_done = 0
        if todo:
            def predict_chunks():
                # ultralytics turns a path list into ONE in-memory batch (ignores `batch`),
                # and 8.4.116 renames them image{i}.jpg: feed chunks, pair results by position
                step = max(1, args.batch)
                for i in range(0, len(todo), step):
                    chunk = todo[i:i + step]
                    yield from zip(chunk, model.predict(
                        source=chunk, imgsz=args.imgsz, conf=args.conf, iou=args.iou,
                        classes=COCO_CLASSES, agnostic_nms=False, verbose=False,
                        device=args.device))
            for img_path, res in predict_chunks():
                dets = []
                if res.boxes is not None and len(res.boxes) > 0:
                    xyxy = res.boxes.xyxy.cpu().numpy()
                    confs = res.boxes.conf.cpu().numpy()
                    clss = res.boxes.cls.cpu().numpy().astype(int)
                    for (x1, y1, x2, y2), conf, cid in zip(xyxy, confs, clss):
                        dets.append({
                            "coco_id": int(cid), "conf": float(conf),
                            "x1": float(x1), "y1": float(y1),
                            "x2": float(x2), "y2": float(y2),
                        })
                proj = nc.coco_to_project(dets)
                inferred[img_path] = proj
                stem = os.path.splitext(os.path.basename(img_path))[0]
                nc.write_yolo_txt(os.path.join(out_root, vname, stem + ".txt"),
                                  [(d["cls"], d["x1"], d["y1"], d["x2"], d["y2"])
                                   for d in proj], nc.SRC_W, nc.SRC_H)
                v_done += 1
                infer_done += 1
                if v_done % 25 == 0:
                    print("  %s: inferred %d/%d, %.1f s elapsed"
                          % (vname, v_done, len(todo), time.time() - t_start),
                          flush=True)
        per_image = []
        for img_path in imgs:
            ap = os.path.abspath(img_path)
            if ap in cached:
                proj = cached[ap]
            elif ap in inferred:
                proj = inferred[ap]
            else:
                print("WARN: no result for %s" % ap, flush=True)
                continue
            for d in proj:
                counts[d["cls"]] += 1
            vbox += len(proj)
            per_image.append((img_path, proj))
        total_imgs += len(per_image)
        total_boxes += vbox
        rows.append([vname, len(per_image)] + counts + [vbox])
        print("%s: %d imgs, %d boxes (inferred %d, cached %d)"
              % (vname, len(per_image), vbox, len(inferred), len(cached)),
              flush=True)

        k = min(max(args.preview_per_video, 0), len(per_image))
        if k > 0:
            idxs = sorted(set(np.linspace(0, len(per_image) - 1, k).round().astype(int).tolist()))
            for i in idxs:
                img_path, proj = per_image[i]
                stem = os.path.splitext(os.path.basename(img_path))[0]
                pv_path = os.path.join(preview_dir, "%s_%s.jpg" % (vname, stem))
                if args.skip_existing and os.path.isfile(pv_path):
                    continue
                img = nc.imread_any(img_path)
                if img is None:
                    continue
                draw_preview(img, proj, pv_path, vname, stem)

    header = ["video", "images"] + list(nc.CLASS_NAMES) + ["total"]
    with open(os.path.join(out_root, "summary.csv"), "w",
              encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for r in rows:
            w.writerow(r)
        sums = [sum(r[i] for r in rows) for i in range(2, len(header) - 1)]
        w.writerow(["TOTAL", total_imgs] + sums + [total_boxes])

    elapsed = time.time() - t_start
    print("images: %d" % total_imgs, flush=True)
    print("boxes: %d" % total_boxes, flush=True)
    print("elapsed: %.1f s" % elapsed, flush=True)


if __name__ == "__main__":
    main()
