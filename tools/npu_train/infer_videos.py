#!/usr/bin/env python3
"""Run offline YOLOv8 inference on road videos with road-band cropping (960x320).

Outputs:
  - <video>_band.mp4: Annotated video in band coordinates (960x320, 30 fps)
  - <video>_dets.csv: Detections mapped to original 1920x1080 frame
  - summary.json: Frame counts, inference timings, class distributions, and args
  - hazard_check.md: Verification against category=HAZARD testcases
"""

import argparse
import csv
import json
import os
from pathlib import Path
import re
import sys
import time


DEFAULT_VIDEOS = [
    "112454", "112507", "112739", "113343", "113421", "113452", "113539"
]
VAL_VIDEOS = {"113343", "113452"}

HAZARD_CLASSES = {
    "lead_close": {"car", "bus", "truck", "tricycle"},
    "cut_in": {"car", "bus", "truck", "tricycle"},
    "ped_in_path": {"person", "rider"},
    "ped_crossing_near": {"person", "rider"},
}

CLASS_COLORS = {
    0: (0, 255, 0),     # person: green
    1: (255, 255, 0),   # rider: cyan
    2: (255, 0, 0),     # car: blue
    3: (0, 165, 255),   # bus: orange
    4: (0, 0, 255),     # truck: red
    5: (255, 0, 255),   # tricycle: magenta
    6: (0, 255, 255),   # cone: yellow
    7: (128, 0, 128),   # barrier: purple
    8: (0, 128, 255),   # speed_limit: amber
}


def check_env_bool(val: str | None, default: bool = False) -> bool:
    """Parse environment variable as boolean following ultralytics env_bool rules."""
    if val is None:
        return default
    return val.strip().lower() in {"1", "true", "yes", "on", "y", "t"}


def check_environment_guard():
    """Verify environment variables before ultralytics import. Exit 2 on failure."""
    cfg_dir = os.environ.get("YOLO_CONFIG_DIR", "").rstrip("/\\")
    autoinstall = os.environ.get("YOLO_AUTOINSTALL")
    offline = os.environ.get("YOLO_OFFLINE")

    errors = []
    if not cfg_dir.endswith(".yolo_cfg_wsl"):
        errors.append(f"YOLO_CONFIG_DIR must end with '.yolo_cfg_wsl' (got: '{cfg_dir}')")
    if autoinstall is None or check_env_bool(autoinstall, default=True):
        errors.append(f"YOLO_AUTOINSTALL must be false (got: '{autoinstall}')")
    if offline is None or not check_env_bool(offline, default=False):
        errors.append(f"YOLO_OFFLINE must be true (got: '{offline}')")

    if errors:
        sys.stderr.write("Environment Guard Error (exit code 2):\n")
        for err in errors:
            sys.stderr.write(f"  - {err}\n")
        sys.exit(2)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run offline YOLOv8 inference on road videos (band 960x320)"
    )
    parser.add_argument(
        "--weights",
        type=str,
        required=True,
        help="Path to YOLO weights (.pt)",
    )
    parser.add_argument(
        "--name",
        type=str,
        required=True,
        help="Run name for output directory under out-root",
    )
    parser.add_argument(
        "--videos",
        type=str,
        nargs="+",
        default=DEFAULT_VIDEOS,
        help="List of videos (short IDs or filenames, default: 7 road videos)",
    )
    parser.add_argument(
        "--out-root",
        type=str,
        default="video_review/npu_runs",
        help="Output root directory (default: video_review/npu_runs)",
    )
    parser.add_argument(
        "--imgsz",
        type=int,
        default=960,
        help="Inference image size (default: 960)",
    )
    parser.add_argument(
        "--conf",
        type=float,
        default=0.25,
        help="Confidence threshold (default: 0.25)",
    )
    parser.add_argument(
        "--iou",
        type=float,
        default=0.6,
        help="NMS IoU threshold (default: 0.6)",
    )
    parser.add_argument(
        "--agnostic",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Class-agnostic NMS (default: True)",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="0",
        help="Inference device (default: '0', use 'cpu' for CPU)",
    )
    parser.add_argument(
        "--max-frames",
        type=int,
        default=0,
        help="Maximum frames per video (0 = all, default: 0)",
    )
    parser.add_argument(
        "--no-video",
        action="store_true",
        default=False,
        help="Do not export annotated mp4 video (CSV only)",
    )
    parser.add_argument(
        "--testcases",
        type=str,
        default="video_review/gt/out/testcases.csv",
        help="Path to testcases.csv (default: video_review/gt/out/testcases.csv)",
    )
    return parser.parse_args()


def resolve_video_targets(video_inputs, root_dir: Path):
    """Resolve video paths and extract short IDs, skipping 111440."""
    src_dir = root_dir / "video_review" / "src"
    raw_list = []
    for item in video_inputs:
        for sub in str(item).split(","):
            sub = sub.strip()
            if sub:
                raw_list.append(sub)

    resolved = []
    seen = set()
    for item in raw_list:
        if "111440" in item:
            print(f"[infer_videos] Skipping non-road video: {item}")
            continue

        p = Path(item)
        if not p.is_absolute():
            candidate_local = root_dir / item
            if candidate_local.is_file():
                p = candidate_local

        if p.is_file():
            v_path = p.resolve()
        else:
            candidates = list(src_dir.glob(f"*{item}*.mp4"))
            if not candidates:
                raise FileNotFoundError(
                    f"Video '{item}' not found in '{src_dir}' or as direct path"
                )
            v_path = candidates[0].resolve()

        m = re.search(r"(?:^|_)(\d{6})$", v_path.stem)
        short_id = m.group(1) if m else v_path.stem.split("_")[-1]

        if short_id == "111440":
            print(f"[infer_videos] Skipping non-road video: {v_path.name}")
            continue

        if short_id not in seen:
            seen.add(short_id)
            resolved.append((short_id, v_path))

    return resolved


def run_hazard_check(testcases_path: Path, processed_video_ids: set, frame_records_by_video: dict, out_md_path: Path):
    """Evaluate detected objects against category=HAZARD testcases."""
    if not testcases_path.is_file():
        sys.stderr.write(f"Warning: testcases file not found: {testcases_path}\n")
        return

    hazard_rows = []
    with open(testcases_path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("category") == "HAZARD" and row.get("video") in processed_video_ids:
                hazard_rows.append(row)

    md_lines = [
        "# HAZARD 核对报告\n",
        "近似指标：画面中部走廊内是否检出相关目标，不等同于判决正确；训练视频上的结果偏乐观\n",
        "| case_id | video | split(train/val) | subtype | t_start | t_end | 窗内帧数 | 命中帧数 | 命中率 |",
        "| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |",
    ]

    train_total = 0
    train_ge50 = 0
    val_total = 0
    val_ge50 = 0

    for row in hazard_rows:
        case_id = row["case_id"]
        vid = row["video"]
        split = "val" if vid in VAL_VIDEOS else "train"
        subtype = row.get("lane_or_side", "")
        t_start = float(row["t_start"])
        t_end = float(row["t_end"])

        frames = frame_records_by_video.get(vid, [])
        window_frames = [
            f for f in frames if (t_start - 1e-4) <= f["t_sec"] <= (t_end + 1e-4)
        ]
        n_window = len(window_frames)

        allowed_classes = HAZARD_CLASSES.get(subtype, set())
        n_hits = 0
        for f_data in window_frames:
            hit = False
            for d in f_data["dets"]:
                if d["cls_name"] in allowed_classes:
                    cx = (d["bx1"] + d["bx2"]) / 2.0
                    # Box center x in [0.30, 0.70] band width, bottom y2_band >= 0.5 * 320
                    if (0.30 * 960.0 <= cx <= 0.70 * 960.0) and (d["by2"] >= 0.5 * 320.0):
                        hit = True
                        break
            if hit:
                n_hits += 1

        hit_rate = (n_hits / n_window) if n_window > 0 else 0.0

        if split == "train":
            train_total += 1
            if hit_rate >= 0.5:
                train_ge50 += 1
        else:
            val_total += 1
            if hit_rate >= 0.5:
                val_ge50 += 1

        md_lines.append(
            f"| {case_id} | {vid} | {split} | {subtype} | {t_start:.1f} | {t_end:.1f} | {n_window} | {n_hits} | {hit_rate:.1%} |"
        )

    total_cases = train_total + val_total
    total_ge50 = train_ge50 + val_ge50

    train_rate_str = f" ({train_ge50 / train_total:.1%})" if train_total > 0 else ""
    val_rate_str = f" ({val_ge50 / val_total:.1%})" if val_total > 0 else ""
    total_rate_str = f" ({total_ge50 / total_cases:.1%})" if total_cases > 0 else ""

    md_lines.append("\n### 汇总（命中率 >= 0.5）")
    md_lines.append(f"- train: {train_ge50} / {train_total}{train_rate_str}")
    md_lines.append(f"- val: {val_ge50} / {val_total}{val_rate_str}")
    md_lines.append(f"- 合计: {total_ge50} / {total_cases}{total_rate_str}\n")

    with open(out_md_path, "w", encoding="utf-8") as f:
        f.write("\n".join(md_lines))


def main():
    if "--help" in sys.argv or "-h" in sys.argv:
        parse_args()
        return

    # Guard check before importing ultralytics or heavy modules
    check_environment_guard()

    args = parse_args()

    project_root = Path(__file__).resolve().parent.parent.parent
    if not (project_root / "video_review").is_dir():
        # Fallback to current working directory
        project_root = Path.cwd().resolve()

    out_root = Path(args.out_root)
    if not out_root.is_absolute():
        out_root = project_root / out_root

    out_dir = out_root / args.name
    if out_dir.exists():
        sys.stderr.write(
            f"Error: Output directory '{out_dir}' already exists (exit code 2).\n"
        )
        sys.exit(2)

    weights_path = Path(args.weights)
    if not weights_path.is_absolute():
        weights_path = project_root / weights_path
    if not weights_path.is_file():
        sys.stderr.write(f"Error: Weights file '{weights_path}' does not exist.\n")
        sys.exit(2)

    testcases_path = Path(args.testcases)
    if not testcases_path.is_absolute():
        testcases_path = project_root / testcases_path

    video_targets = resolve_video_targets(args.videos, project_root)
    if not video_targets:
        sys.stderr.write("Error: No valid road videos to process.\n")
        sys.exit(1)

    # Now import heavy packages
    import cv2
    tools_dir = Path(__file__).resolve().parent
    if str(tools_dir) not in sys.path:
        sys.path.insert(0, str(tools_dir))
    from npu_common import CLASS_NAMES, band_crop_resize
    from ultralytics import YOLO

    out_dir.mkdir(parents=True, exist_ok=True)
    model = YOLO(str(weights_path))

    video_summaries = {}
    frame_records_by_video = {}

    for short_id, v_path in video_targets:
        cap = cv2.VideoCapture(str(v_path))
        if not cap.isOpened():
            sys.stderr.write(f"Error: Failed to open video: {v_path}\n")
            continue

        fps = cap.get(cv2.CAP_PROP_FPS)
        if fps <= 0.0 or fps != fps:
            fps = 30.0

        out_mp4 = out_dir / f"{short_id}_band.mp4"
        out_csv = out_dir / f"{short_id}_dets.csv"

        writer = None
        if not args.no_video:
            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            writer = cv2.VideoWriter(str(out_mp4), fourcc, fps, (960, 320))

        frame_idx = 0
        total_infer_time_s = 0.0
        video_dets = []
        frame_records = []
        class_counts = {name: 0 for name in CLASS_NAMES}

        while True:
            if args.max_frames > 0 and frame_idx >= args.max_frames:
                break
            ret, frame = cap.read()
            if not ret:
                break

            t_sec = frame_idx / fps
            band = band_crop_resize(frame)

            t0 = time.perf_counter()
            results = model.predict(
                band,
                imgsz=args.imgsz,
                conf=args.conf,
                iou=args.iou,
                agnostic_nms=args.agnostic,
                device=args.device,
                verbose=False,
            )
            t1 = time.perf_counter()
            total_infer_time_s += (t1 - t0)

            vis = band.copy() if writer is not None else None
            frame_dets_list = []

            res = results[0]
            if res.boxes is not None and len(res.boxes) > 0:
                for box in res.boxes:
                    bx1, by1, bx2, by2 = box.xyxy[0].tolist()
                    score = float(box.conf[0].item())
                    cls_id = int(box.cls[0].item())
                    cls_name = model.names.get(
                        cls_id,
                        CLASS_NAMES[cls_id] if cls_id < len(CLASS_NAMES) else str(cls_id),
                    )

                    if cls_name in class_counts:
                        class_counts[cls_name] += 1

                    # Coordinate mapping back to original 1920x1080 frame
                    x1 = bx1 * 2.0
                    y1 = by1 * 2.0 + 360.0
                    x2 = bx2 * 2.0
                    y2 = by2 * 2.0 + 360.0

                    det_info = {
                        "video": short_id,
                        "frame": frame_idx,
                        "t_sec": t_sec,
                        "cls": cls_id,
                        "cls_name": cls_name,
                        "conf": score,
                        "x1": x1,
                        "y1": y1,
                        "x2": x2,
                        "y2": y2,
                        "bx1": bx1,
                        "by1": by1,
                        "bx2": bx2,
                        "by2": by2,
                    }
                    video_dets.append(det_info)
                    frame_dets_list.append(det_info)

                    if vis is not None:
                        color = CLASS_COLORS.get(cls_id, (0, 255, 0))
                        p1 = (int(round(bx1)), int(round(by1)))
                        p2 = (int(round(bx2)), int(round(by2)))
                        cv2.rectangle(vis, p1, p2, color, 2)

                        label_text = f"{cls_name} {score:.2f}"
                        font = cv2.FONT_HERSHEY_SIMPLEX
                        font_scale = 0.45
                        thickness = 1
                        (tw, th), baseline = cv2.getTextSize(
                            label_text, font, font_scale, thickness
                        )
                        ty = max(int(round(by1)) - 4, th + 2)
                        tx = max(int(round(bx1)), 0)
                        cv2.rectangle(
                            vis,
                            (tx, ty - th - 2),
                            (tx + tw + 2, ty + baseline - 1),
                            color,
                            -1,
                        )
                        cv2.putText(
                            vis,
                            label_text,
                            (tx + 1, ty - 1),
                            font,
                            font_scale,
                            (255, 255, 255),
                            thickness,
                            cv2.LINE_AA,
                        )

            if vis is not None:
                info_text = f"frame: {frame_idx}  time: {t_sec:.2f}s"
                cv2.putText(
                    vis,
                    info_text,
                    (10, 25),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.7,
                    (0, 0, 0),
                    3,
                    cv2.LINE_AA,
                )
                cv2.putText(
                    vis,
                    info_text,
                    (10, 25),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.7,
                    (255, 255, 255),
                    1,
                    cv2.LINE_AA,
                )
                writer.write(vis)

            frame_records.append(
                {"frame": frame_idx, "t_sec": t_sec, "dets": frame_dets_list}
            )
            frame_idx += 1

        cap.release()
        if writer is not None:
            writer.release()

        with open(out_csv, "w", newline="", encoding="utf-8") as f:
            csv_w = csv.writer(f)
            csv_w.writerow(
                ["video", "frame", "t_sec", "cls", "cls_name", "conf", "x1", "y1", "x2", "y2"]
            )
            for d in video_dets:
                csv_w.writerow([
                    d["video"],
                    d["frame"],
                    f"{d['t_sec']:.3f}",
                    d["cls"],
                    d["cls_name"],
                    f"{d['conf']:.4f}",
                    f"{d['x1']:.1f}",
                    f"{d['y1']:.1f}",
                    f"{d['x2']:.1f}",
                    f"{d['y2']:.1f}",
                ])

        avg_infer_ms = (
            (total_infer_time_s * 1000.0 / frame_idx) if frame_idx > 0 else 0.0
        )
        video_summaries[short_id] = {
            "frames": frame_idx,
            "avg_infer_ms": round(avg_infer_ms, 2),
            "class_counts": class_counts,
        }
        frame_records_by_video[short_id] = frame_records

        counts_str = ", ".join(f"{k}: {v}" for k, v in class_counts.items())
        print(
            f"[{short_id}] frames: {frame_idx}, avg_ms: {avg_infer_ms:.1f}, class_counts: {{{counts_str}}}"
        )

    summary_data = {
        "args": {
            "weights": args.weights,
            "name": args.name,
            "videos": [sid for sid, _ in video_targets],
            "out_root": args.out_root,
            "imgsz": args.imgsz,
            "conf": args.conf,
            "iou": args.iou,
            "agnostic": args.agnostic,
            "device": args.device,
            "max_frames": args.max_frames,
            "no_video": args.no_video,
            "testcases": args.testcases,
        },
        "videos": video_summaries,
    }
    with open(out_dir / "summary.json", "w", encoding="utf-8") as f:
        json.dump(summary_data, f, indent=2, ensure_ascii=False)

    processed_ids = set(video_summaries.keys())
    run_hazard_check(
        testcases_path,
        processed_ids,
        frame_records_by_video,
        out_dir / "hazard_check.md",
    )


if __name__ == "__main__":
    main()
