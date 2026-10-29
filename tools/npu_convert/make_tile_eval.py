"""Build 2x2 tiled validation set (960x320) from npu_v2w validation set.

Reads 73 validation images from datasets/npu_v2w/images/val and labels from
datasets/npu_v2w/labels/val.
Tiles groups of 4 images (downsampled to 480x160) into a 2x2 grid of 960x320:
  - Top-Left:     (x: 0..480,   y: 0..160)
  - Top-Right:    (x: 480..960, y: 0..160)
  - Bottom-Left:  (x: 0..480,   y: 160..320)
  - Bottom-Right: (x: 480..960, y: 160..320)
Cycles through all 73 images until covered (19 tiles total; the 19th tile uses
the 73rd image and wraps around to images 0, 1, 2).
Transforms bounding boxes accordingly and outputs to:
  datasets/npu_v2w_tile/images/val
  datasets/npu_v2w_tile/labels/val
  datasets/npu_v2w_tile/data.yaml
"""

import argparse
import math
import os
import sys

import cv2
import numpy as np
import yaml

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROJECT_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))

QUADRANTS = [
    (0, 0),  # Top-Left:     row=0, col=0
    (0, 1),  # Top-Right:    row=0, col=1
    (1, 0),  # Bottom-Left:  row=1, col=0
    (1, 1),  # Bottom-Right: row=1, col=1
]


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Build 2x2 tiled eval set")
    ap.add_argument("--src-dir", default=os.path.join(_PROJECT_ROOT, "datasets", "npu_v2w"))
    ap.add_argument("--out-dir", default=os.path.join(_PROJECT_ROOT, "datasets", "npu_v2w_tile"))
    ap.add_argument("--jpeg-quality", type=int, default=95)
    ap.add_argument("--overwrite", action="store_true")
    return ap.parse_args(argv)


def read_yolo_labels(lbl_path):
    if not os.path.isfile(lbl_path):
        return []
    boxes = []
    with open(lbl_path, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) >= 5:
                cls_id = int(parts[0])
                xc, yc, w, h = (float(v) for v in parts[1:5])
                boxes.append((cls_id, xc, yc, w, h))
    return boxes


def transform_box(cls_id, xc, yc, w, h, row, col):
    """Transform normalized YOLO box from original image into 2x2 tile quadrant."""
    # Convert normalized coords to quadrant [0, 1] bounds
    qx1 = max(0.0, min(1.0, xc - w / 2.0))
    qy1 = max(0.0, min(1.0, yc - h / 2.0))
    qx2 = max(0.0, min(1.0, xc + w / 2.0))
    qy2 = max(0.0, min(1.0, yc + h / 2.0))

    if qx2 <= qx1 or qy2 <= qy1:
        return None

    # Quadrant normalized range within the 960x320 canvas:
    # x in [col*0.5, (col+1)*0.5], y in [row*0.5, (row+1)*0.5]
    cx1 = col * 0.5 + qx1 * 0.5
    cx2 = col * 0.5 + qx2 * 0.5
    cy1 = row * 0.5 + qy1 * 0.5
    cy2 = row * 0.5 + qy2 * 0.5

    # Clamp to quadrant bounds
    cx1 = max(col * 0.5, min((col + 1) * 0.5, cx1))
    cx2 = max(col * 0.5, min((col + 1) * 0.5, cx2))
    cy1 = max(row * 0.5, min((row + 1) * 0.5, cy1))
    cy2 = max(row * 0.5, min((row + 1) * 0.5, cy2))

    cw = cx2 - cx1
    ch = cy2 - cy1
    if cw <= 1e-6 or ch <= 1e-6:
        return None

    cxc = (cx1 + cx2) / 2.0
    cyc = (cy1 + cy2) / 2.0
    return cls_id, cxc, cyc, cw, ch


def main(argv=None):
    args = parse_args(argv)

    src_img_dir = os.path.join(args.src_dir, "images", "val")
    src_lbl_dir = os.path.join(args.src_dir, "labels", "val")

    if not os.path.isdir(src_img_dir):
        print(f"ERROR: source image dir not found: {src_img_dir}", file=sys.stderr)
        return 2

    valid_exts = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
    img_files = sorted(f for f in os.listdir(src_img_dir) if os.path.splitext(f)[1].lower() in valid_exts)
    total_imgs = len(img_files)
    if total_imgs == 0:
        print(f"ERROR: no images found under {src_img_dir}", file=sys.stderr)
        return 2

    print(f"Found {total_imgs} validation images in {src_img_dir}")

    out_img_dir = os.path.join(args.out_dir, "images", "val")
    out_lbl_dir = os.path.join(args.out_dir, "labels", "val")
    os.makedirs(out_img_dir, exist_ok=True)
    os.makedirs(out_lbl_dir, exist_ok=True)

    num_tiles = int(math.ceil(total_imgs / 4.0))
    print(f"Generating {num_tiles} 2x2 tiles...")

    for tile_idx in range(num_tiles):
        canvas = np.zeros((320, 960, 3), dtype=np.uint8)
        tile_boxes = []

        for q_idx, (row, col) in enumerate(QUADRANTS):
            src_idx = (tile_idx * 4 + q_idx) % total_imgs
            src_fname = img_files[src_idx]
            src_img_path = os.path.join(src_img_dir, src_fname)
            src_stem = os.path.splitext(src_fname)[0]
            src_lbl_path = os.path.join(src_lbl_dir, src_stem + ".txt")

            buf = np.fromfile(src_img_path, dtype=np.uint8)
            img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
            if img is None:
                raise IOError(f"Failed to read image: {src_img_path}")

            # Downsample to 480x160
            sub_img = cv2.resize(img, (480, 160), interpolation=cv2.INTER_AREA)

            y0 = row * 160
            y1 = (row + 1) * 160
            x0 = col * 480
            x1 = (col + 1) * 480
            canvas[y0:y1, x0:x1] = sub_img

            # Load and transform labels
            boxes = read_yolo_labels(src_lbl_path)
            for cls_id, xc, yc, w, h in boxes:
                tb = transform_box(cls_id, xc, yc, w, h, row, col)
                if tb is not None:
                    tile_boxes.append(tb)

        # Write output tile image
        out_fname = f"tile_{tile_idx:03d}.jpg"
        out_img_path = os.path.join(out_img_dir, out_fname)
        ok, buf = cv2.imencode(".jpg", canvas, [int(cv2.IMWRITE_JPEG_QUALITY), args.jpeg_quality])
        if not ok:
            raise IOError(f"Failed to encode jpg: {out_img_path}")
        buf.tofile(out_img_path)

        # Write output label txt
        out_lbl_path = os.path.join(out_lbl_dir, f"tile_{tile_idx:03d}.txt")
        with open(out_lbl_path, "w", encoding="utf-8", newline="\n") as f:
            for cls_id, cxc, cyc, cw, ch in tile_boxes:
                f.write(f"{cls_id} {cxc:.6f} {cyc:.6f} {cw:.6f} {ch:.6f}\n")

    # Generate data.yaml
    src_yaml_path = os.path.join(args.src_dir, "data.yaml")
    names_dict = {}
    if os.path.isfile(src_yaml_path):
        with open(src_yaml_path, "r", encoding="utf-8") as f:
            cfg = yaml.safe_load(f)
            names_dict = cfg.get("names", {})

    tile_yaml = {
        "path": "/mnt/e/Project/nesai2026/datasets/npu_v2w_tile",
        "train": "images/val",
        "val": "images/val",
        "nc": len(names_dict) if names_dict else 9,
        "names": names_dict if names_dict else {
            0: "person", 1: "rider", 2: "car", 3: "bus", 4: "truck",
            5: "tricycle", 6: "cone", 7: "barrier", 8: "speed_limit"
        },
    }

    out_yaml_path = os.path.join(args.out_dir, "data.yaml")
    with open(out_yaml_path, "w", encoding="utf-8") as f:
        yaml.dump(tile_yaml, f, sort_keys=False)

    print(f"Generated {num_tiles} tile images and labels in {args.out_dir}")
    print(f"Saved {out_yaml_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
