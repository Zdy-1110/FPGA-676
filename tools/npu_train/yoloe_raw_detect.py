"""Raw inference on frame pool with prompt-free YOLOE model for 9 vocabulary categories.

Outputs JSON Lines detections and confidence statistics for train/val splits.
"""

import argparse
import glob
import json
import os
import sys
import time
from collections import defaultdict
from pathlib import Path

import torch
from ultralytics import YOLO

TARGET_VOCAB = [
    "tricycle",
    "rickshaw",
    "traffic cone",
    "cone",
    "barricade",
    "barrier",
    "fence",
    "speed limit sign",
    "speed limit",
]

VAL_VIDEOS = {
    "video_20260929_113343",
    "video_20260929_113452",
}

CONF_BINS = [
    ("0.10-0.2", 0.10, 0.20),
    ("0.2-0.3", 0.20, 0.30),
    ("0.3-0.4", 0.30, 0.40),
    ("0.4-0.5", 0.40, 0.50),
    (">=0.5", 0.50, float("inf")),
]


def parse_args():
    p = argparse.ArgumentParser(description="Raw YOLOE detection on frame pool")
    p.add_argument("--pool", required=True, help="Path to frame pool directory")
    p.add_argument("--weights", required=True, help="Path to model weights (.pt)")
    p.add_argument("--imgsz", type=int, default=1280, help="Inference image size")
    p.add_argument("--conf", type=float, default=0.10, help="Confidence threshold")
    p.add_argument("--device", default="0", help="CUDA device ID or 'cpu'")
    p.add_argument("--batch", type=int, default=4, help="Batch size for chunked predict")
    p.add_argument("--out", required=True, help="Output directory")
    return p.parse_args()


def collect_images(pool_dir):
    videos = sorted([d for d in os.listdir(pool_dir) if os.path.isdir(os.path.join(pool_dir, d))])
    all_items = []
    for v in videos:
        v_path = os.path.join(pool_dir, v)
        imgs = sorted(glob.glob(os.path.join(v_path, "*.jpg")))
        for img in imgs:
            all_items.append((v, img))
    return all_items


def get_conf_bin(conf):
    for label, low, high in CONF_BINS:
        if low <= conf < high:
            return label
    if conf >= 0.50:
        return ">=0.5"
    return "0.10-0.2"


def main():
    args = parse_args()
    t_start = time.time()

    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)
    jsonl_path = os.path.join(out_dir, "detections.jsonl")

    # Load model
    print(f"Loading model from: {args.weights}", flush=True)
    model = YOLO(args.weights)
    print(f"Model loaded successfully. Total classes in model: {len(model.names)}", flush=True)

    # Match target vocabulary by name and get class IDs
    name_to_id = {v: k for k, v in model.names.items()}
    target_id_to_name = {}
    target_class_ids = []

    print("\nTarget vocabulary mapping (name -> class_id):", flush=True)
    for name in TARGET_VOCAB:
        if name not in name_to_id:
            raise ValueError(f"Category '{name}' not found in model vocabulary!")
        cid = name_to_id[name]
        target_id_to_name[cid] = name
        target_class_ids.append(cid)
        print(f"  - {name}: {cid}", flush=True)

    # Collect images
    all_items = collect_images(args.pool)
    total_imgs = len(all_items)
    print(f"\nCollected {total_imgs} images from {args.pool}", flush=True)
    if total_imgs != 1457:
        print(f"WARNING: Expected 1457 images, but found {total_imgs}!", flush=True)

    # Reset peak memory stats if CUDA
    is_cuda = (args.device != "cpu" and torch.cuda.is_available())
    if is_cuda:
        torch.cuda.reset_peak_memory_stats()

    # Statistics counters
    # counts[split][term][bin]
    stats = {
        "train": {t: {b[0]: 0 for b in CONF_BINS} for t in TARGET_VOCAB},
        "val": {t: {b[0]: 0 for b in CONF_BINS} for t in TARGET_VOCAB},
    }
    for split in ["train", "val"]:
        for t in TARGET_VOCAB:
            stats[split][t]["total"] = 0

    processed_count = 0
    total_dets_count = 0

    step = max(1, args.batch)
    print(f"\nStarting inference: imgsz={args.imgsz}, conf={args.conf}, batch={args.batch}, device={args.device}", flush=True)

    with open(jsonl_path, "w", encoding="utf-8", newline="\n") as f_out:
        for i in range(0, total_imgs, step):
            chunk = all_items[i:i + step]
            paths = [p for _, p in chunk]

            # VRAM safety check
            if is_cuda:
                allocated_gb = torch.cuda.memory_allocated() / (1024 ** 3)
                if allocated_gb > 12.0:
                    raise RuntimeError(f"GPU memory exceeded 12 GB ({allocated_gb:.2f} GB)! Stopping execution.")

            # Chunked predict to avoid 8.4.116 memory leak / filename lost bug
            results = model.predict(
                source=paths,
                imgsz=args.imgsz,
                conf=args.conf,
                classes=target_class_ids,
                device=args.device,
                verbose=False,
            )

            for (vname, img_path), res in zip(chunk, results):
                img_name = os.path.basename(img_path)
                split = "val" if vname in VAL_VIDEOS else "train"
                dets = []

                if res.boxes is not None and len(res.boxes) > 0:
                    xyxy_arr = res.boxes.xyxy.cpu().numpy()
                    conf_arr = res.boxes.conf.cpu().numpy()
                    cls_arr = res.boxes.cls.cpu().numpy().astype(int)

                    for (x1, y1, x2, y2), conf, cid in zip(xyxy_arr, conf_arr, cls_arr):
                        if cid in target_id_to_name:
                            cname = target_id_to_name[cid]
                            fconf = float(conf)
                            det_item = {
                                "name": cname,
                                "conf": round(fconf, 4),
                                "xyxy": [round(float(x1), 1), round(float(y1), 1),
                                         round(float(x2), 1), round(float(y2), 1)],
                            }
                            dets.append(det_item)

                            # Tally stats
                            cbin = get_conf_bin(fconf)
                            stats[split][cname][cbin] += 1
                            stats[split][cname]["total"] += 1
                            total_dets_count += 1

                dets.sort(key=lambda d: d["conf"], reverse=True)
                line_data = {
                    "video": vname,
                    "image": img_name,
                    "det": dets,
                }
                f_out.write(json.dumps(line_data, ensure_ascii=False) + "\n")
                processed_count += 1

            if processed_count % 100 == 0 or processed_count == total_imgs:
                elapsed = time.time() - t_start
                vram_info = ""
                if is_cuda:
                    vram_cur = torch.cuda.memory_allocated() / (1024 ** 3)
                    vram_peak = torch.cuda.max_memory_allocated() / (1024 ** 3)
                    vram_info = f", VRAM cur: {vram_cur:.2f}GB, peak: {vram_peak:.2f}GB"
                fps = processed_count / elapsed if elapsed > 0 else 0
                print(f"  Processed {processed_count}/{total_imgs} images ({fps:.1f} img/s{vram_info})", flush=True)

    elapsed_total = time.time() - t_start
    print(f"\nInference completed in {elapsed_total:.2f} s. Processed {processed_count} images, saved to {jsonl_path}", flush=True)

    peak_vram_gb = 0.0
    if is_cuda:
        peak_vram_gb = torch.cuda.max_memory_allocated() / (1024 ** 3)
        print(f"GPU Peak VRAM: {peak_vram_gb:.2f} GB", flush=True)

    # Print and save stats tables
    bin_headers = [b[0] for b in CONF_BINS]
    table_header = f"{'Category':<18} | {'Split':<5} | " + " | ".join(f"{b:>8}" for b in bin_headers) + f" | {'Total':>7}"
    separator = "-" * len(table_header)

    lines = []
    lines.append("\n" + separator)
    lines.append("Detection Counts by Category, Split, and Confidence Bin:")
    lines.append(separator)
    lines.append(table_header)
    lines.append(separator)

    for t in TARGET_VOCAB:
        for split in ["train", "val"]:
            row_vals = [f"{stats[split][t][b]:>8}" for b in bin_headers]
            tot = f"{stats[split][t]['total']:>7}"
            lines.append(f"{t:<18} | {split:<5} | " + " | ".join(row_vals) + f" | {tot}")
        lines.append(separator)

    # Combined total per category
    lines.append(f"{'Category':<18} | {'Split':<5} | " + " | ".join(f"{b:>8}" for b in bin_headers) + f" | {'Total':>7}")
    lines.append(separator)
    for t in TARGET_VOCAB:
        comb_vals = []
        comb_tot = 0
        for b in bin_headers:
            cnt = stats["train"][t][b] + stats["val"][t][b]
            comb_vals.append(f"{cnt:>8}")
            comb_tot += cnt
        lines.append(f"{t:<18} | {'all':<5} | " + " | ".join(comb_vals) + f" | {comb_tot:>7}")
    lines.append(separator + "\n")

    full_table_text = "\n".join(lines)
    print(full_table_text, flush=True)

    # Save stats files
    with open(os.path.join(out_dir, "stats.txt"), "w", encoding="utf-8") as f_txt:
        f_txt.write(full_table_text)

    stats_meta = {
        "elapsed_seconds": round(elapsed_total, 2),
        "total_images": processed_count,
        "total_detections": total_dets_count,
        "peak_vram_gb": round(peak_vram_gb, 3),
        "stats": stats,
    }
    with open(os.path.join(out_dir, "stats.json"), "w", encoding="utf-8") as f_json:
        json.dump(stats_meta, f_json, indent=2, ensure_ascii=False)

    print(f"Stats written to {os.path.join(out_dir, 'stats.txt')} and {os.path.join(out_dir, 'stats.json')}", flush=True)


if __name__ == "__main__":
    main()
