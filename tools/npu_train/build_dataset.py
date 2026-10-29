"""Build the 960x320 road-band dataset from pre-labels (no training)."""

import argparse
import glob
import json
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import npu_common as nc

COLORS = [
    (0, 0, 255), (0, 165, 255), (255, 128, 0), (255, 0, 255), (0, 255, 255),
    (255, 255, 0), (128, 0, 255), (0, 128, 255), (255, 0, 0),
]


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--labels", default="datasets/npu_labels/prelabel_v8s1280")
    p.add_argument("--pool", default="video_review/label_pool")
    p.add_argument("--out", default="datasets/npu_v1")
    p.add_argument("--val-videos", nargs="+", required=True)
    p.add_argument("--exclude-videos", nargs="*", default=[])
    p.add_argument("--repeat", nargs="*", default=[])
    p.add_argument("--band", nargs=2, type=int, default=[360, 1000])
    p.add_argument("--size", nargs=2, type=int, default=[960, 320])
    p.add_argument("--min-vis", type=float, default=0.3)
    p.add_argument("--min-h-out", type=float, default=4.0)
    p.add_argument("--max-y2", type=float, default=None)
    p.add_argument("--max-area-frac", type=float, default=0.0)
    p.add_argument("--video-max-y2", nargs="*", default=[])
    p.add_argument("--video-max-w", nargs="*", default=[])
    p.add_argument("--jpg-quality", type=int, default=95)
    p.add_argument("--preview-per-video", type=int, default=1)
    p.add_argument("--overwrite", action="store_true")
    return p.parse_args()


def parse_video_floats(items, flag):
    out = {}
    for item in items:
        if "=" not in item:
            raise SystemExit("ERROR: %s item must be VIDEO=VALUE: %s" % (flag, item))
        name, val = item.rsplit("=", 1)
        try:
            v = float(val)
        except ValueError:
            raise SystemExit("ERROR: bad %s value: %s" % (flag, item))
        out[name] = v
    return out


def parse_repeat(items):
    rep = {}
    for item in items:
        if "=" not in item:
            raise SystemExit("ERROR: --repeat item must be VIDEO=N: %s" % item)
        name, val = item.rsplit("=", 1)
        try:
            n = int(val)
        except ValueError:
            raise SystemExit("ERROR: bad repeat count: %s" % item)
        if n < 0:
            raise SystemExit("ERROR: repeat must be >= 0: %s" % item)
        rep[name] = n
    return rep


def write_jpg(path, img, quality):
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    ok, buf = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), int(quality)])
    if not ok:
        raise IOError("cv2.imencode failed: %s" % path)
    buf.tofile(path)


def band_drop_reason(box, y0, y1, src_w, out_w, out_h, min_vis, min_h_out):
    cls, x1, y1b, x2, y2b = box
    area = max(0.0, x2 - x1) * max(0.0, y2b - y1b)
    if area <= 0.0:
        return "vis"
    cx1 = min(max(x1, 0.0), float(src_w))
    cx2 = min(max(x2, 0.0), float(src_w))
    cy1 = min(max(y1b, float(y0)), float(y1))
    cy2 = min(max(y2b, float(y0)), float(y1))
    if cx2 <= cx1 or cy2 <= cy1:
        return "vis"
    vis = (cx2 - cx1) * (cy2 - cy1) / area
    if vis < min_vis:
        return "vis"
    h_out = (cy2 - cy1) * float(out_h) / float(y1 - y0)
    if h_out < min_h_out:
        return "h"
    return None


def draw_preview(img, boxes, video, stem, out_path):
    vis = img.copy()
    for cls, x1, y1, x2, y2 in boxes:
        color = COLORS[int(cls) % len(COLORS)]
        p1 = (int(round(x1)), int(round(y1)))
        p2 = (int(round(x2)), int(round(y2)))
        cv2.rectangle(vis, p1, p2, color, 2)
        label = nc.CLASS_NAMES[int(cls)]
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
        ty = max(p1[1] - 4, th + 2)
        cv2.rectangle(vis, (p1[0], ty - th - 3), (p1[0] + tw + 4, ty + 2), color, -1)
        cv2.putText(vis, label, (p1[0] + 2, ty - 1), cv2.FONT_HERSHEY_SIMPLEX,
                    0.6, (0, 0, 0), 2, cv2.LINE_AA)
    cv2.putText(vis, "%s / %s" % (video, stem), (8, 20),
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2, cv2.LINE_AA)
    write_jpg(out_path, vis, 95)


def main():
    args = parse_args()
    pool = os.path.abspath(args.pool)
    labels_root = os.path.abspath(args.labels)
    out = os.path.abspath(args.out)
    y0, y1 = args.band
    out_w, out_h = args.size
    src_area = float(nc.SRC_W * nc.SRC_H)

    if os.path.exists(out) and not args.overwrite:
        print("ERROR: output exists, use --overwrite: %s" % out, flush=True)
        return 2

    repeat_map = parse_repeat(args.repeat)
    video_y2 = parse_video_floats(args.video_max_y2, "--video-max-y2")
    video_w = parse_video_floats(args.video_max_w, "--video-max-w")
    exclude = set(args.exclude_videos)
    all_videos = sorted(d for d in os.listdir(pool) if os.path.isdir(os.path.join(pool, d)))
    missing_rule = [v for v in list(video_y2) + list(video_w) if v not in all_videos]
    if missing_rule:
        print("ERROR: rule video not found in pool: %s" % ", ".join(sorted(set(missing_rule))),
              flush=True)
        return 2
    missing_val = [v for v in args.val_videos if v not in all_videos]
    if missing_val:
        print("ERROR: val video not found: %s" % ", ".join(missing_val), flush=True)
        return 2
    conflict = [v for v in args.val_videos if v in exclude]
    if conflict:
        print("ERROR: video both in val and exclude: %s" % ", ".join(conflict), flush=True)
        return 2
    val_set = set(args.val_videos)
    videos = [v for v in all_videos if v not in exclude]
    unknown = [v for v in repeat_map if v not in videos or v in val_set]
    if unknown:
        print("ERROR: --repeat only applies to train videos: %s" % ", ".join(unknown),
              flush=True)
        return 2

    for split in ("train", "val"):
        os.makedirs(os.path.join(out, "images", split), exist_ok=True)
        os.makedirs(os.path.join(out, "labels", split), exist_ok=True)
    preview_dir = os.path.join(out, "_preview")
    os.makedirs(preview_dir, exist_ok=True)

    params = {
        "labels": labels_root, "pool": pool, "out": out,
        "val_videos": list(args.val_videos),
        "exclude_videos": list(args.exclude_videos),
        "repeat": dict(repeat_map), "band": [y0, y1], "size": [out_w, out_h],
        "min_vis": args.min_vis, "min_h_out": args.min_h_out,
        "max_y2": args.max_y2, "max_area_frac": args.max_area_frac,
        "video_max_y2": dict(video_y2), "video_max_w": dict(video_w),
        "jpg_quality": args.jpg_quality,
        "preview_per_video": args.preview_per_video,
    }

    generated = set()
    stats_videos = []
    split_stats = {
        "train": {"images": 0, "empty_labels": 0, "boxes": [0] * len(nc.CLASS_NAMES)},
        "val": {"images": 0, "empty_labels": 0, "boxes": [0] * len(nc.CLASS_NAMES)},
    }

    for vname in videos:
        split = "val" if vname in val_set else "train"
        rep = 1 if split == "val" else repeat_map.get(vname, 1)
        jpgs = sorted(glob.glob(os.path.join(pool, vname, "*.jpg")))
        eff_y2 = args.max_y2
        if vname in video_y2:
            eff_y2 = video_y2[vname] if eff_y2 is None else min(eff_y2, video_y2[vname])
        eff_w = video_w.get(vname)
        eff_area = args.max_area_frac if args.max_area_frac > 0 else None
        st = {
            "video": vname, "split": split, "repeat": rep, "images": len(jpgs),
            "src_boxes": 0, "drop_y2": 0, "drop_w": 0, "drop_area": 0,
            "drop_vis": 0, "drop_h": 0, "kept": 0,
            "max_y2": eff_y2, "max_w": eff_w, "max_area_frac": eff_area,
        }
        preview_items = []
        for img_path in jpgs:
            stem = os.path.splitext(os.path.basename(img_path))[0]
            txt_in = os.path.join(labels_root, vname, stem + ".txt")
            if not os.path.isfile(txt_in):
                print("ERROR: missing label: %s" % txt_in, flush=True)
                return 2
            src_boxes = nc.read_yolo_txt(txt_in, nc.SRC_W, nc.SRC_H)
            st["src_boxes"] += len(src_boxes)

            clean = []
            for b in src_boxes:
                cls, x1, by1, x2, by2 = b
                if eff_y2 is not None and by2 > eff_y2:
                    st["drop_y2"] += 1
                    continue
                if eff_w is not None and (x2 - x1) > eff_w:
                    st["drop_w"] += 1
                    continue
                if eff_area is not None and (x2 - x1) * (by2 - by1) > eff_area * src_area:
                    st["drop_area"] += 1
                    continue
                clean.append(b)

            band_boxes = nc.boxes_to_band(clean, y0=y0, y1=y1, src_w=nc.SRC_W,
                                          out_w=out_w, out_h=out_h,
                                          min_vis=args.min_vis,
                                          min_h_out=args.min_h_out)
            dropped = 0
            for b in clean:
                reason = band_drop_reason(b, y0, y1, nc.SRC_W, out_w, out_h,
                                          args.min_vis, args.min_h_out)
                if reason == "vis":
                    st["drop_vis"] += 1
                    dropped += 1
                elif reason == "h":
                    st["drop_h"] += 1
                    dropped += 1
            if dropped != len(clean) - len(band_boxes):
                print("ERROR: drop accounting mismatch for %s/%s (%d vs %d)"
                      % (vname, stem, dropped, len(clean) - len(band_boxes)),
                      flush=True)
                return 3
            st["kept"] += len(band_boxes)

            img = nc.imread_any(img_path)
            if img is None:
                print("ERROR: cannot read image: %s" % img_path, flush=True)
                return 2
            band_img = nc.band_crop_resize(img, y0, y1, out_w, out_h)

            copies = rep if split == "train" else 1
            for k in range(1, copies + 1):
                suffix = "" if k == 1 else "__r%d" % k
                base = "%s__%s%s" % (vname, stem, suffix)
                img_out = os.path.join(out, "images", split, base + ".jpg")
                lbl_out = os.path.join(out, "labels", split, base + ".txt")
                write_jpg(img_out, band_img, args.jpg_quality)
                nc.write_yolo_txt(lbl_out,
                                  [(int(c), x1, by1, x2, by2)
                                   for c, x1, by1, x2, by2 in band_boxes],
                                  out_w, out_h)
                generated.add(os.path.abspath(img_out))
                generated.add(os.path.abspath(lbl_out))
                split_stats[split]["images"] += 1
                if not band_boxes:
                    split_stats[split]["empty_labels"] += 1
                for c, _x1, _y1, _x2, _y2 in band_boxes:
                    split_stats[split]["boxes"][int(c)] += 1

            if band_boxes:
                preview_items.append((img_path, stem, band_img, band_boxes))

        stats_videos.append(st)
        if preview_items:
            k = min(max(args.preview_per_video, 0), len(preview_items))
            if k > 0:
                idxs = sorted(set(np.linspace(0, len(preview_items) - 1, k)
                                  .round().astype(int).tolist()))
                for i in idxs:
                    _p, stem, band_img, band_boxes = preview_items[i]
                    pv = os.path.join(preview_dir, "%s__%s.jpg" % (vname, stem))
                    draw_preview(band_img, band_boxes, vname, stem, pv)
                    generated.add(os.path.abspath(pv))

    data = {
        "path": out.replace("\\", "/"),
        "train": "images/train",
        "val": "images/val",
        "nc": len(nc.CLASS_NAMES),
        "names": {i: n for i, n in enumerate(nc.CLASS_NAMES)},
    }
    yaml_path = os.path.join(out, "data.yaml")
    with open(yaml_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("path: %s\n" % data["path"])
        f.write("train: %s\n" % data["train"])
        f.write("val: %s\n" % data["val"])
        f.write("nc: %d\n" % data["nc"])
        f.write("names:\n")
        for i, n in data["names"].items():
            f.write("  %d: %s\n" % (i, n))
    generated.add(os.path.abspath(yaml_path))

    for split in ("train", "val"):
        split_stats[split]["total_boxes"] = int(sum(split_stats[split]["boxes"]))
        split_stats[split]["boxes"] = {
            n: c for n, c in zip(nc.CLASS_NAMES, split_stats[split]["boxes"])
        }
    stats = {
        "params": params,
        "splits": split_stats,
        "videos": stats_videos,
        "data_yaml": data,
    }
    stats_path = os.path.join(out, "stats.json")
    with open(stats_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(stats, f, ensure_ascii=False, indent=2)
    generated.add(os.path.abspath(stats_path))

    cmd_path = os.path.join(out, "build_cmd.txt")
    with open(cmd_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(" ".join(sys.argv) + "\n")
    generated.add(os.path.abspath(cmd_path))

    print("\nvideo                    split rep imgs  src    y2   w area vis h  kept   eff_y2 eff_w eff_area",
          flush=True)
    for st in stats_videos:
        print("%-24s %-5s %3d %4d %5d %5d %4d %4d %3d %1d %5d   %s %s %s"
              % (st["video"], st["split"], st["repeat"], st["images"],
                 st["src_boxes"], st["drop_y2"], st["drop_w"], st["drop_area"],
                 st["drop_vis"], st["drop_h"], st["kept"],
                 st["max_y2"], st["max_w"], st["max_area_frac"]), flush=True)
    for split in ("train", "val"):
        s = split_stats[split]
        print("[%s] images=%d empty=%d total_boxes=%d %s"
              % (split, s["images"], s["empty_labels"], s["total_boxes"],
                 json.dumps(s["boxes"], ensure_ascii=False)), flush=True)

    extras = []
    for root, _dirs, files in os.walk(out):
        for fn in files:
            full = os.path.abspath(os.path.join(root, fn))
            if full in generated:
                continue
            if fn.endswith(".cache"):
                continue
            extras.append(full)
    if extras:
        print("NOTE: %d pre-existing file(s) not regenerated (not deleted)" % len(extras),
              flush=True)
        for e in extras[:10]:
            print("  " + e, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
