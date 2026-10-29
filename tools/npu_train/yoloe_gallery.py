"""Build visual review gallery from raw YOLOE detections.

Generates cropped grid images (_high, _mid, _low) and full-frame context images (conf 0.2-0.4)
for each target vocabulary category. Runs on CPU only.
"""

import argparse
import json
import math
import os
import sys
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np

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


def parse_args():
    p = argparse.ArgumentParser(description="Build YOLOE review gallery")
    p.add_argument("--jsonl", default="runs/yoloe_raw/pf11l_6fps/detections.jsonl",
                   help="Path to detections.jsonl")
    p.add_argument("--pool", default="video_review/label_pool_6fps",
                   help="Path to frame pool root directory")
    p.add_argument("--out", default="runs/yoloe_raw/pf11l_6fps/gallery",
                   help="Output directory for gallery images")
    return p.parse_args()


def crop_detection(img, xyxy):
    """Crop detection box expanded by 20% with min dimension >= 96px, resized to h=128."""
    img_h, img_w = img.shape[:2]
    x1, y1, x2, y2 = xyxy
    bw = max(1.0, x2 - x1)
    bh = max(1.0, y2 - y1)
    cx = (x1 + x2) / 2.0
    cy = (y1 + y2) / 2.0

    # Expand by 20%
    target_w = bw * 1.2
    target_h = bh * 1.2

    # Min edge >= 96 px
    if target_w < 96.0:
        target_w = 96.0
    if target_h < 96.0:
        target_h = 96.0

    # Calculate coordinates
    x1_c = int(round(cx - target_w / 2.0))
    x2_c = int(round(cx + target_w / 2.0))
    y1_c = int(round(cy - target_h / 2.0))
    y2_c = int(round(cy + target_h / 2.0))

    # Clamp and shift within image boundaries
    if x1_c < 0:
        x2_c = min(img_w, x2_c - x1_c)
        x1_c = 0
    if x2_c > img_w:
        x1_c = max(0, x1_c - (x2_c - img_w))
        x2_c = img_w
    x1_c = max(0, min(img_w - 1, x1_c))
    x2_c = max(x1_c + 1, min(img_w, x2_c))

    if y1_c < 0:
        y2_c = min(img_h, y2_c - y1_c)
        y1_c = 0
    if y2_c > img_h:
        y1_c = max(0, y1_c - (y2_c - img_h))
        y2_c = img_h
    y1_c = max(0, min(img_h - 1, y1_c))
    y2_c = max(y1_c + 1, min(img_h, y2_c))

    crop = img[y1_c:y2_c, x1_c:x2_c]
    if crop.size == 0 or crop.shape[0] == 0 or crop.shape[1] == 0:
        return None

    # Maintain aspect ratio, resize to height 128
    ch, cw = crop.shape[:2]
    scale = 128.0 / float(ch)
    new_w = max(1, int(round(cw * scale)))
    interp = cv2.INTER_AREA if scale < 1.0 else cv2.INTER_LINEAR
    resized_crop = cv2.resize(crop, (new_w, 128), interpolation=interp)
    return resized_crop


def parse_timestamp(img_name):
    """Extract timestamp string such as t0.00 from filename."""
    stem = os.path.splitext(img_name)[0]
    parts = stem.split("_")
    for p in reversed(parts):
        if p.startswith("t") and len(p) > 1:
            return p
    return parts[-1]


def render_grid_image(crops_data, term, tier_name):
    """Render up to 60 crops into a clean grid image."""
    n = len(crops_data)
    if n == 0:
        return None

    # Determine grid layout (max 10 columns)
    ncols = min(10, n)
    nrows = int(math.ceil(n / float(ncols)))

    # Determine cell width based on crops (clamped 150..240)
    scaled_widths = [c["crop"].shape[1] for c in crops_data]
    max_w = max(scaled_widths)
    cell_w = max(150, min(240, max_w))
    cell_h = 128 + 26  # 128 for image + 26 for label banner
    pad = 6
    title_h = 36

    grid_w = pad + ncols * (cell_w + pad)
    grid_h = title_h + pad + nrows * (cell_h + pad)

    grid_img = np.full((grid_h, grid_w, 3), 32, dtype=np.uint8)

    # Draw Title Banner
    conf_min = min(c["conf"] for c in crops_data)
    conf_max = max(c["conf"] for c in crops_data)
    title_text = f"[{term}] Tier: {tier_name.upper()} | Crops: {n} | Conf Range: {conf_min:.3f} - {conf_max:.3f}"
    cv2.putText(grid_img, title_text, (pad + 4, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 255, 255), 2, cv2.LINE_AA)

    for idx, cdata in enumerate(crops_data):
        r = idx // ncols
        col = idx % ncols
        x_cell = pad + col * (cell_w + pad)
        y_cell = title_h + pad + r * (cell_h + pad)

        # Fill cell background
        grid_img[y_cell:y_cell + cell_h, x_cell:x_cell + cell_w] = (42, 42, 42)

        crop = cdata["crop"]
        ch, cw = crop.shape[:2]

        # Fit crop within cell_w x 128 if wider than cell_w
        if cw > cell_w:
            scale_fit = float(cell_w) / float(cw)
            fit_w = cell_w
            fit_h = max(1, int(round(ch * scale_fit)))
            c_draw = cv2.resize(crop, (fit_w, fit_h), interpolation=cv2.INTER_AREA)
        else:
            c_draw = crop
            fit_w = cw
            fit_h = ch

        # Center in image area
        x_off = x_cell + (cell_w - fit_w) // 2
        y_off = y_cell + (128 - fit_h) // 2
        grid_img[y_off:y_off + fit_h, x_off:x_off + fit_w] = c_draw

        # Text banner
        y_text = y_cell + 128
        grid_img[y_text:y_cell + cell_h, x_cell:x_cell + cell_w] = (24, 24, 24)

        label_text = f"{cdata['conf']:.2f} {cdata['video_suffix']} {cdata['timestamp']}"
        (tw, th), _ = cv2.getTextSize(label_text, cv2.FONT_HERSHEY_SIMPLEX, 0.40, 1)
        tx = x_cell + max(2, (cell_w - tw) // 2)
        ty = y_text + 17
        cv2.putText(grid_img, label_text, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.40, (255, 255, 255), 1, cv2.LINE_AA)

        # Border around cell
        cv2.rectangle(grid_img, (x_cell, y_cell), (x_cell + cell_w, y_cell + cell_h), (70, 70, 70), 1)

    return grid_img


def create_safe_symlink(target_path, link_path):
    """Create relative symlink if link_path does not exist."""
    if os.path.exists(link_path) or os.path.islink(link_path):
        return
    rel_target = os.path.relpath(target_path, os.path.dirname(link_path))
    try:
        os.symlink(rel_target, link_path)
    except Exception as e:
        print(f"Warning: Failed to create symlink {link_path} -> {rel_target}: {e}")


def main():
    args = parse_args()
    out_dir = os.path.abspath(args.out)
    pool_dir = os.path.abspath(args.pool)
    os.makedirs(out_dir, exist_ok=True)

    print(f"Reading detections from: {args.jsonl}")
    with open(args.jsonl, "r", encoding="utf-8") as f:
        records = [json.loads(line) for line in f]

    print(f"Loaded {len(records)} image records from jsonl.")

    # Group detections by category
    # cat_dets[cname] = list of {video, image, conf, xyxy}
    cat_dets = defaultdict(list)
    # image_dets[(video, image)][cname] = list of {conf, xyxy}
    image_dets = defaultdict(lambda: defaultdict(list))

    for rec in records:
        vname = rec["video"]
        iname = rec["image"]
        for d in rec.get("det", []):
            cname = d["name"]
            item = {
                "video": vname,
                "image": iname,
                "conf": d["conf"],
                "xyxy": d["xyxy"],
            }
            cat_dets[cname].append(item)
            image_dets[(vname, iname)][cname].append(item)

    # Sort each category's detections descending by confidence
    for cname in cat_dets:
        cat_dets[cname].sort(key=lambda d: d["conf"], reverse=True)

    generated_files = []

    # Process each category
    print("\n--- Generating Gallery Grid Images ---")
    for term in TARGET_VOCAB:
        dets = cat_dets[term]
        n_dets = len(dets)
        term_safe = term.replace(" ", "_")

        if n_dets == 0:
            print(f"Category '{term}': 0 detections (skipping grid)")
            continue

        print(f"Category '{term}': {n_dets} detections total.")

        # Determine tiers to generate (at most 3 images: high, mid, low)
        tiers_to_build = []
        if n_dets <= 60:
            # All fit in one image: high
            tiers_to_build.append(("high", dets[:60]))
        else:
            # 3 images: high, mid, low
            tiers_to_build.append(("high", dets[:60]))
            mid_start = (n_dets - 60) // 2
            tiers_to_build.append(("mid", dets[mid_start:mid_start + 60]))
            tiers_to_build.append(("low", dets[-60:]))

        # Cache loaded images to avoid reloading when multiple crops come from same image
        img_cache = {}

        def get_img(vname, iname):
            key = (vname, iname)
            if key not in img_cache:
                path = os.path.join(pool_dir, vname, iname)
                mat = cv2.imread(path)
                img_cache[key] = mat
            return img_cache[key]

        saved_tier_files = {}

        for tier_name, tier_dets in tiers_to_build:
            crops_data = []
            for d in tier_dets:
                img_mat = get_img(d["video"], d["image"])
                if img_mat is None:
                    continue
                crop = crop_detection(img_mat, d["xyxy"])
                if crop is not None:
                    crops_data.append({
                        "crop": crop,
                        "conf": d["conf"],
                        "video_suffix": d["video"][-6:],
                        "timestamp": parse_timestamp(d["image"]),
                    })

            if not crops_data:
                continue

            grid_img = render_grid_image(crops_data, term, tier_name)
            if grid_img is not None:
                filename = f"{term_safe}_{tier_name}.jpg"
                out_path = os.path.join(out_dir, filename)
                cv2.imwrite(out_path, grid_img, [cv2.IMWRITE_JPEG_QUALITY, 92])
                generated_files.append(filename)
                saved_tier_files[tier_name] = out_path
                print(f"  Saved: {filename} ({len(crops_data)} crops)")

                # If category name has spaces, create symlink with original space name
                if " " in term:
                    space_filename = f"{term}_{tier_name}.jpg"
                    create_safe_symlink(out_path, os.path.join(out_dir, space_filename))
                    generated_files.append(space_filename)

        # For n_dets <= 60, symlink mid and low to high so that all expected tier files exist
        if n_dets <= 60 and "high" in saved_tier_files:
            high_path = saved_tier_files["high"]
            for tier_name in ["mid", "low"]:
                filename = f"{term_safe}_{tier_name}.jpg"
                create_safe_symlink(high_path, os.path.join(out_dir, filename))
                generated_files.append(filename)
                if " " in term:
                    space_filename = f"{term}_{tier_name}.jpg"
                    create_safe_symlink(high_path, os.path.join(out_dir, space_filename))
                    generated_files.append(space_filename)

    # Context full images (3 images per category, prioritizing conf 0.2 - 0.4)
    print("\n--- Generating Context Full Images (gallery/full_<term>_*.jpg) ---")
    for term in TARGET_VOCAB:
        term_safe = term.replace(" ", "_")
        dets = cat_dets[term]
        if not dets:
            print(f"Category '{term}': 0 detections (no full images)")
            continue

        # Group detections by image (vname, iname)
        img_to_dets = defaultdict(list)
        for d in dets:
            img_to_dets[(d["video"], d["image"])].append(d)

        # Separate candidate images: in [0.2, 0.4] vs outside
        cands_in_range = []
        cands_other = []

        for (vname, iname), dlist in img_to_dets.items():
            max_c = max(d["conf"] for d in dlist)
            has_range = any(0.20 <= d["conf"] <= 0.40 for d in dlist)
            if has_range:
                cands_in_range.append((vname, iname, max_c, dlist))
            else:
                cands_other.append((vname, iname, max_c, dlist))

        # Sort candidate images deterministically by (video, image)
        cands_in_range.sort(key=lambda x: (x[0], x[1]))
        # Sort other candidates by distance to 0.30
        cands_other.sort(key=lambda x: abs(x[2] - 0.30))

        chosen_images = []
        if len(cands_in_range) >= 3:
            # Pick 3 spread out across the timeline
            m = len(cands_in_range)
            chosen_indices = [0, m // 2, m - 1]
            chosen_images = [cands_in_range[idx] for idx in chosen_indices]
        else:
            chosen_images.extend(cands_in_range)
            needed = 3 - len(chosen_images)
            chosen_images.extend(cands_other[:needed])

        print(f"Category '{term}': Selected {len(chosen_images)} full context images.")

        for idx, (vname, iname, _, _) in enumerate(chosen_images, start=1):
            raw_path = os.path.join(pool_dir, vname, iname)
            full_img = cv2.imread(raw_path)
            if full_img is None:
                continue

            # Draw ALL detections of this category on this full image
            all_cat_dets_here = image_dets[(vname, iname)][term]
            for d in all_cat_dets_here:
                x1, y1, x2, y2 = [int(round(coord)) for coord in d["xyxy"]]
                conf = d["conf"]

                # Draw bounding box
                cv2.rectangle(full_img, (x1, y1), (x2, y2), (0, 0, 255), 3)

                # Draw label
                label = f"{term} {conf:.2f}"
                (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.75, 2)
                by = max(0, y1 - th - 8)
                cv2.rectangle(full_img, (x1, by), (x1 + tw + 6, by + th + 8), (0, 0, 255), -1)
                cv2.putText(full_img, label, (x1 + 3, by + th + 4), cv2.FONT_HERSHEY_SIMPLEX,
                            0.75, (255, 255, 255), 2, cv2.LINE_AA)

            v_suffix = vname[-6:]
            t_str = parse_timestamp(iname)
            stem = os.path.splitext(iname)[0]

            out_name = f"full_{term_safe}_{idx:02d}_{v_suffix}_{t_str}.jpg"
            out_path = os.path.join(out_dir, out_name)
            cv2.imwrite(out_path, full_img, [cv2.IMWRITE_JPEG_QUALITY, 90])
            generated_files.append(out_name)
            print(f"  Saved full image: {out_name} (dets: {len(all_cat_dets_here)})")

            # Symlinks for standard patterns
            short_name = f"full_{term_safe}_{idx}.jpg"
            create_safe_symlink(out_path, os.path.join(out_dir, short_name))
            generated_files.append(short_name)

            if " " in term:
                space_out_name = f"full_{term}_{idx:02d}_{v_suffix}_{t_str}.jpg"
                space_short_name = f"full_{term}_{idx}.jpg"
                create_safe_symlink(out_path, os.path.join(out_dir, space_out_name))
                create_safe_symlink(out_path, os.path.join(out_dir, space_short_name))
                generated_files.append(space_out_name)
                generated_files.append(space_short_name)

    print(f"\nGallery generation finished. Total files/symlinks in gallery: {len(generated_files)}")


if __name__ == "__main__":
    main()
