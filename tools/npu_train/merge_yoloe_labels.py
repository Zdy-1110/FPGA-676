"""Merge raw YOLOE detections into teacher labels (CPU only).

Rules:
- cone(6): "traffic cone" & "cone", conf >= 0.35, NMS IoU 0.5 (keep higher conf).
- tricycle(5): "tricycle", conf >= 0.55; drop if video == "video_20260929_113539" and x2 < 200.
- speed_limit(8): "speed limit sign" & "speed limit", conf >= 0.50, NMS IoU 0.5.
- barrier(7): no auto labeling.
- Conflicts (only against accepted tricycle):
  - delete teacher box with IoU >= 0.5 if class in {0, 1, 2, 3, 4} (bus added 10-26: a blue e-tricycle was also labelled bus, IoU 0.92)
  - delete teacher person(0) box if >= 70% of its area is inside tricycle.
- Validation videos: untouched (byte-for-byte copy).
"""

import argparse
import glob
import json
import os
import shutil
import sys
from collections import defaultdict

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import npu_common as nc

COLORS = [
    (0, 0, 255),      # 0 person: red
    (0, 165, 255),    # 1 rider: orange
    (255, 128, 0),    # 2 car: cyan
    (255, 0, 255),    # 3 bus: magenta
    (0, 255, 255),    # 4 truck: yellow
    (255, 255, 0),    # 5 tricycle: cyan-yellow / sky blue
    (128, 0, 255),    # 6 cone: violet
    (0, 128, 255),    # 7 barrier: orange-brown
    (255, 0, 0),      # 8 speed_limit: blue
]


def parse_args():
    p = argparse.ArgumentParser(description="Merge raw YOLOE detections into teacher pre-labels")
    p.add_argument("--teacher", default="datasets/npu_labels/prelabel_v8s1280_6fps",
                   help="Path to teacher labels directory")
    p.add_argument("--yoloe", default="runs/yoloe_raw/pf11l_6fps/detections.jsonl",
                   help="Path to YOLOE detections.jsonl")
    p.add_argument("--out", default="datasets/npu_labels/prelabel_v8s1280_6fps_yoloe",
                   help="Output directory for merged labels")
    p.add_argument("--val-videos", nargs="+",
                   default=["video_20260929_113343", "video_20260929_113452"],
                   help="Validation video names to copy untouched")
    p.add_argument("--pool", default="video_review/label_pool_6fps",
                   help="Frame pool root directory (for generating review images)")
    p.add_argument("--review-dir", default=None,
                   help="Directory for check images (default: <out>/_review)")
    p.add_argument("--num-review", type=int, default=12,
                   help="Number of check images to generate (default: 12)")
    p.add_argument("--report", default=None,
                   help="Output path for merge_report.json (default: <out>/merge_report.json)")
    return p.parse_args()


def box_iou(b1, b2):
    """Compute IoU between two [x1, y1, x2, y2] boxes."""
    ix1 = max(b1[0], b2[0])
    iy1 = max(b1[1], b2[1])
    ix2 = min(b1[2], b2[2])
    iy2 = min(b1[3], b2[3])
    iw = max(0.0, ix2 - ix1)
    ih = max(0.0, iy2 - iy1)
    inter = iw * ih
    a1 = max(0.0, b1[2] - b1[0]) * max(0.0, b1[3] - b1[1])
    a2 = max(0.0, b2[2] - b2[0]) * max(0.0, b2[3] - b2[1])
    union = a1 + a2 - inter
    return inter / union if union > 0 else 0.0


def frac_inside(inner, outer):
    """Compute fraction of inner box area that falls inside outer box."""
    ix1 = max(inner[0], outer[0])
    iy1 = max(inner[1], outer[1])
    ix2 = min(inner[2], outer[2])
    iy2 = min(inner[3], outer[3])
    iw = max(0.0, ix2 - ix1)
    ih = max(0.0, iy2 - iy1)
    inter = iw * ih
    a_inner = max(0.0, inner[2] - inner[0]) * max(0.0, inner[3] - inner[1])
    return inter / a_inner if a_inner > 0 else 0.0


def nms(dets, iou_thresh=0.5):
    """NMS on list of dicts with 'conf' and 'xyxy'."""
    dets = sorted(dets, key=lambda x: x["conf"], reverse=True)
    kept = []
    for d in dets:
        suppress = False
        for k in kept:
            if box_iou(d["xyxy"], k["xyxy"]) >= iou_thresh:
                suppress = True
                break
        if not suppress:
            kept.append(d)
    return kept


def draw_labeled_boxes(img, boxes, video, stem, out_path):
    """Draw boxes on 1920x1080 image and save."""
    vis = img.copy()
    for b in boxes:
        cls = int(b[0])
        x1, y1, x2, y2 = b[1:5]
        color = COLORS[cls % len(COLORS)]
        p1 = (int(round(x1)), int(round(y1)))
        p2 = (int(round(x2)), int(round(y2)))
        cv2.rectangle(vis, p1, p2, color, 2)
        label = nc.CLASS_NAMES[cls] if cls < len(nc.CLASS_NAMES) else str(cls)
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
        ty = max(p1[1] - 4, th + 2)
        cv2.rectangle(vis, (p1[0], ty - th - 3), (p1[0] + tw + 4, ty + 2), color, -1)
        cv2.putText(vis, label, (p1[0] + 2, ty - 1), cv2.FONT_HERSHEY_SIMPLEX,
                    0.6, (0, 0, 0), 2, cv2.LINE_AA)
    header = f"{video} / {stem}"
    cv2.putText(vis, header, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2, cv2.LINE_AA)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    ok, buf = cv2.imencode(".jpg", vis, [int(cv2.IMWRITE_JPEG_QUALITY), 95])
    if ok:
        buf.tofile(out_path)


def main():
    args = parse_args()
    teacher_root = os.path.abspath(args.teacher)
    yoloe_path = os.path.abspath(args.yoloe)
    out_root = os.path.abspath(args.out)
    pool_root = os.path.abspath(args.pool)
    val_set = set(args.val_videos)
    review_dir = os.path.abspath(args.review_dir) if args.review_dir else os.path.join(out_root, "_review")
    report_path = os.path.abspath(args.report) if args.report else os.path.join(out_root, "merge_report.json")

    if not os.path.isdir(teacher_root):
        print(f"ERROR: teacher directory not found: {teacher_root}", flush=True)
        return 2
    if not os.path.isfile(yoloe_path):
        print(f"ERROR: yoloe file not found: {yoloe_path}", flush=True)
        return 2

    os.makedirs(out_root, exist_ok=True)
    os.makedirs(review_dir, exist_ok=True)

    # 1. Read YOLOE detections indexed by (video, image)
    detections_by_frame = {}
    with open(yoloe_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            data = json.loads(line)
            v = data["video"]
            img = data["image"]
            detections_by_frame[(v, img)] = data.get("det", [])

    # Discover videos in teacher root
    teacher_videos = sorted(
        d for d in os.listdir(teacher_root)
        if os.path.isdir(os.path.join(teacher_root, d)) and not d.startswith("_")
    )

    report_by_video = {}
    filtered_tri_details = []
    conflict_del_details = []

    # Track frames for review selection
    frames_with_conflict = []
    frames_with_tricycle = []
    frames_with_speed_limit = []
    frames_with_cone = []

    # Track final box counts for summary.csv
    video_box_counts = {}

    for vname in teacher_videos:
        v_in_dir = os.path.join(teacher_root, vname)
        v_out_dir = os.path.join(out_root, vname)
        os.makedirs(v_out_dir, exist_ok=True)

        is_val = vname in val_set
        v_stats = {
            "is_val": is_val,
            "images": 0,
            "new_boxes": defaultdict(int),
            "del_teacher": defaultdict(int),
            "filtered_tricycle_count": 0,
        }

        txt_files = sorted(glob.glob(os.path.join(v_in_dir, "*.txt")))
        v_stats["images"] = len(txt_files)
        box_counts_per_class = [0] * len(nc.CLASS_NAMES)

        if is_val:
            # Byte-for-byte copy validation video files
            for txt_in in txt_files:
                base = os.path.basename(txt_in)
                txt_out = os.path.join(v_out_dir, base)
                shutil.copyfile(txt_in, txt_out)
                # Count boxes for summary.csv
                boxes = nc.read_yolo_txt(txt_out, nc.SRC_W, nc.SRC_H)
                for b in boxes:
                    cls = int(b[0])
                    if 0 <= cls < len(box_counts_per_class):
                        box_counts_per_class[cls] += 1
            report_by_video[vname] = v_stats
            video_box_counts[vname] = box_counts_per_class
            continue

        # Process training video
        for txt_in in txt_files:
            stem = os.path.splitext(os.path.basename(txt_in))[0]
            img_name = stem + ".jpg"
            raw_dets = detections_by_frame.get((vname, img_name), [])

            # 1. cone(6): "traffic cone" & "cone", conf >= 0.35, NMS IoU 0.5
            cone_cands = [
                d for d in raw_dets
                if d.get("name") in ("traffic cone", "cone") and float(d.get("conf", 0.0)) >= 0.35
            ]
            cone_kept = nms(cone_cands, 0.5)

            # 2. tricycle(5): "tricycle", conf >= 0.55; drop if video_20260929_113539 & x2 < 200
            tri_cands = [
                d for d in raw_dets
                if d.get("name") == "tricycle" and float(d.get("conf", 0.0)) >= 0.55
            ]
            tri_kept = []
            for d in tri_cands:
                x1, y1, x2, y2 = d["xyxy"]
                if vname == "video_20260929_113539" and x2 < 200.0:
                    v_stats["filtered_tricycle_count"] += 1
                    filtered_tri_details.append({
                        "video": vname,
                        "image": img_name,
                        "conf": d.get("conf"),
                        "xyxy": d.get("xyxy"),
                        "reason": "video_20260929_113539 and x2 < 200",
                    })
                else:
                    tri_kept.append(d)

            # 3. speed_limit(8): "speed limit sign" & "speed limit", conf >= 0.50, NMS IoU 0.5
            speed_cands = [
                d for d in raw_dets
                if d.get("name") in ("speed limit sign", "speed limit") and float(d.get("conf", 0.0)) >= 0.50
            ]
            speed_kept = nms(speed_cands, 0.5)

            # 4. Read teacher boxes and apply conflict resolution
            teacher_boxes_raw = []
            if os.path.isfile(txt_in):
                with open(txt_in, "r", encoding="utf-8") as tf:
                    for line in tf:
                        parts = line.strip().split()
                        if len(parts) < 5:
                            continue
                        cls = int(float(parts[0]))
                        cx, cy, w, h = (float(v) for v in parts[1:5])
                        x1 = (cx - w / 2.0) * nc.SRC_W
                        y1 = (cy - h / 2.0) * nc.SRC_H
                        x2 = (cx + w / 2.0) * nc.SRC_W
                        y2 = (cy + h / 2.0) * nc.SRC_H
                        teacher_boxes_raw.append({
                            "line": line.strip(),
                            "cls": cls,
                            "xyxy": [x1, y1, x2, y2],
                        })

            kept_teacher_lines = []
            has_conflict = False
            for tb in teacher_boxes_raw:
                tcls = tb["cls"]
                tbox = tb["xyxy"]
                deleted = False
                del_reason = ""
                for tri in tri_kept:
                    tribox = tri["xyxy"]
                    iou = box_iou(tbox, tribox)
                    inside = frac_inside(tbox, tribox)
                    if tcls in (0, 1, 2, 3, 4) and iou >= 0.5:
                        deleted = True
                        del_reason = f"IoU={iou:.4f}>=0.5 with tricycle {tribox}"
                        break
                    if tcls == 0 and inside >= 0.70:
                        deleted = True
                        del_reason = f"person inside tricycle fraction={inside:.4f}>=0.70 {tribox}"
                        break
                if deleted:
                    has_conflict = True
                    v_stats["del_teacher"][tcls] += 1
                    conflict_del_details.append({
                        "video": vname,
                        "image": img_name,
                        "cls": tcls,
                        "cls_name": nc.CLASS_NAMES[tcls],
                        "xyxy": tbox,
                        "reason": del_reason,
                    })
                else:
                    kept_teacher_lines.append(tb["line"])
                    if 0 <= tcls < len(box_counts_per_class):
                        box_counts_per_class[tcls] += 1

            # Build new boxes list
            new_lines = []
            for d in tri_kept:
                x1, y1, x2, y2 = d["xyxy"]
                cx = (x1 + x2) / 2.0 / nc.SRC_W
                cy = (y1 + y2) / 2.0 / nc.SRC_H
                w = (x2 - x1) / nc.SRC_W
                h = (y2 - y1) / nc.SRC_H
                new_lines.append(f"5 {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}")
                v_stats["new_boxes"][5] += 1
                box_counts_per_class[5] += 1

            for d in cone_kept:
                x1, y1, x2, y2 = d["xyxy"]
                cx = (x1 + x2) / 2.0 / nc.SRC_W
                cy = (y1 + y2) / 2.0 / nc.SRC_H
                w = (x2 - x1) / nc.SRC_W
                h = (y2 - y1) / nc.SRC_H
                new_lines.append(f"6 {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}")
                v_stats["new_boxes"][6] += 1
                box_counts_per_class[6] += 1

            for d in speed_kept:
                x1, y1, x2, y2 = d["xyxy"]
                cx = (x1 + x2) / 2.0 / nc.SRC_W
                cy = (y1 + y2) / 2.0 / nc.SRC_H
                w = (x2 - x1) / nc.SRC_W
                h = (y2 - y1) / nc.SRC_H
                new_lines.append(f"8 {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}")
                v_stats["new_boxes"][8] += 1
                box_counts_per_class[8] += 1

            # Record review candidates
            if has_conflict:
                frames_with_conflict.append((vname, stem, img_name))
            if tri_kept:
                frames_with_tricycle.append((vname, stem, img_name))
            if speed_kept:
                frames_with_speed_limit.append((vname, stem, img_name))
            if cone_kept:
                frames_with_cone.append((vname, stem, img_name))

            # Write merged label file
            txt_out = os.path.join(v_out_dir, os.path.basename(txt_in))
            all_lines = kept_teacher_lines + new_lines
            content = "\n".join(all_lines)
            if content:
                content += "\n"
            with open(txt_out, "w", encoding="utf-8", newline="\n") as out_f:
                out_f.write(content)

        report_by_video[vname] = v_stats
        video_box_counts[vname] = box_counts_per_class

    # 2. Write classes.txt
    classes_txt_src = os.path.join(teacher_root, "classes.txt")
    classes_txt_dst = os.path.join(out_root, "classes.txt")
    if os.path.isfile(classes_txt_src):
        shutil.copyfile(classes_txt_src, classes_txt_dst)
    else:
        with open(classes_txt_dst, "w", encoding="utf-8", newline="\n") as cf:
            for name in nc.CLASS_NAMES:
                cf.write(f"{name}\n")

    # 3. Write summary.csv
    summary_csv_path = os.path.join(out_root, "summary.csv")
    with open(summary_csv_path, "w", encoding="utf-8", newline="\n") as sf:
        sf.write("video,images," + ",".join(nc.CLASS_NAMES) + ",total\n")
        tot_imgs = 0
        tot_boxes = [0] * len(nc.CLASS_NAMES)
        for vname in teacher_videos:
            counts = video_box_counts[vname]
            v_imgs = report_by_video[vname]["images"]
            tot_imgs += v_imgs
            for i in range(len(nc.CLASS_NAMES)):
                tot_boxes[i] += counts[i]
            sf.write(f"{vname},{v_imgs}," + ",".join(str(c) for c in counts) + f",{sum(counts)}\n")
        sf.write(f"TOTAL,{tot_imgs}," + ",".join(str(c) for c in tot_boxes) + f",{sum(tot_boxes)}\n")

    # 4. Compile merge_report.json
    total_new = defaultdict(int)
    total_del = defaultdict(int)
    total_filtered_tri = 0
    by_video_json = {}
    for vname, st in report_by_video.items():
        by_video_json[vname] = {
            "is_val": st["is_val"],
            "images": st["images"],
            "new_boxes": {nc.CLASS_NAMES[k]: v for k, v in sorted(st["new_boxes"].items())},
            "new_boxes_by_class_id": {str(k): v for k, v in sorted(st["new_boxes"].items())},
            "del_teacher_boxes": {nc.CLASS_NAMES[k]: v for k, v in sorted(st["del_teacher"].items())},
            "del_teacher_boxes_by_class_id": {str(k): v for k, v in sorted(st["del_teacher"].items())},
            "filtered_tricycle_count": st["filtered_tricycle_count"],
        }
        for k, v in st["new_boxes"].items():
            total_new[k] += v
        for k, v in st["del_teacher"].items():
            total_del[k] += v
        total_filtered_tri += st["filtered_tricycle_count"]

    merge_report = {
        "summary": {
            "total_new_boxes": {nc.CLASS_NAMES[k]: v for k, v in sorted(total_new.items())},
            "total_new_boxes_by_class_id": {str(k): v for k, v in sorted(total_new.items())},
            "total_del_teacher_boxes": {nc.CLASS_NAMES[k]: v for k, v in sorted(total_del.items())},
            "total_del_teacher_boxes_by_class_id": {str(k): v for k, v in sorted(total_del.items())},
            "total_filtered_tricycle_count": total_filtered_tri,
        },
        "by_video": by_video_json,
        "filtered_tricycles_details": filtered_tri_details,
        "conflict_del_details": conflict_del_details,
    }

    with open(report_path, "w", encoding="utf-8", newline="\n") as rf:
        json.dump(merge_report, rf, ensure_ascii=False, indent=2)
    print(f"Merge report written to {report_path}", flush=True)

    # 5. Generate 12 check images (covering conflict deletions, tricycle, speed_limit, and cone across videos)
    selected_frames = []

    def add_from_list(cand_list, max_add):
        added = 0
        for item in cand_list:
            if item not in selected_frames:
                selected_frames.append(item)
                added += 1
                if added >= max_add:
                    break

    # 1. Conflict frames (3 frames: person del, car del, truck del)
    # t45.17 (person del), t45.67 (car del), t46.17 (truck del)
    conflict_diverse = []
    seen_del_cls = set()
    for item in frames_with_conflict:
        v, stem, _ = item
        # check which class was deleted
        for cd in conflict_del_details:
            if cd["video"] == v and cd["image"] == stem + ".jpg":
                if cd["cls"] not in seen_del_cls:
                    seen_del_cls.add(cd["cls"])
                    conflict_diverse.append(item)
                    break
    add_from_list(conflict_diverse, 3)
    add_from_list(frames_with_conflict, 3)

    # 2. Tricycle frames without conflict (2 frames: e.g. t48.83, t53.33)
    tri_no_conflict = [item for item in frames_with_tricycle if item not in frames_with_conflict]
    add_from_list(tri_no_conflict, 2)

    # 3. Speed limit frames across diverse videos (3 frames)
    # group by video
    speed_by_video = defaultdict(list)
    for item in frames_with_speed_limit:
        speed_by_video[item[0]].append(item)
    for v in sorted(speed_by_video.keys()):
        add_from_list(speed_by_video[v], 1)
        if len([x for x in selected_frames if x in frames_with_speed_limit]) >= 4:
            break

    # 4. Cone frames across diverse videos (remaining up to args.num_review)
    cone_by_video = defaultdict(list)
    for item in frames_with_cone:
        cone_by_video[item[0]].append(item)
    for v in sorted(cone_by_video.keys()):
        add_from_list(cone_by_video[v], 1)
        if len(selected_frames) >= args.num_review:
            break

    # Fill any remaining slots
    all_cands = frames_with_conflict + frames_with_tricycle + frames_with_speed_limit + frames_with_cone
    add_from_list(all_cands, args.num_review - len(selected_frames))

    selected_frames = selected_frames[:args.num_review]
    print(f"Generating {len(selected_frames)} check images in {review_dir}...", flush=True)
    generated_reviews = []
    for vname, stem, img_name in selected_frames:
        img_path = os.path.join(pool_root, vname, img_name)
        txt_path = os.path.join(out_root, vname, stem + ".txt")
        if not os.path.isfile(img_path) or not os.path.isfile(txt_path):
            continue
        img = nc.imread_any(img_path)
        if img is None:
            continue
        boxes = nc.read_yolo_txt(txt_path, nc.SRC_W, nc.SRC_H)
        out_img_path = os.path.join(review_dir, f"{vname}__{stem}.jpg")
        draw_labeled_boxes(img, boxes, vname, stem, out_img_path)
        generated_reviews.append(out_img_path)

    print(f"Successfully generated {len(generated_reviews)} check images.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
