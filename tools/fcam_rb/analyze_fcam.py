#!/usr/bin/env python3
"""
tools/fcam_rb/analyze_fcam.py - Image quality and noise analysis for FPGA front camera raw RGB565 frames.
Format: 960x540 RGB565 (RB_SWAP=1: bit[4:0]=R, bit[10:5]=G, bit[15:11]=B).
"""

import sys
import os
import glob
import json
import math
import argparse
import numpy as np
from PIL import Image

WIDTH = 960
HEIGHT = 540
FRAME_PIXELS = WIDTH * HEIGHT
FRAME_BYTES = FRAME_PIXELS * 2

def parse_args():
    parser = argparse.ArgumentParser(description="Analyze FPGA front camera RGB565 frames")
    parser.add_argument("inputs", nargs="+", help="Input .rgb565 file(s) or glob pattern(s)")
    parser.add_argument("--png", help="Export first frame as PNG")
    parser.add_argument("--roi", help="White reference ROI: x0,y0,x1,y1")
    parser.add_argument("--json", dest="json_out", help="Output all metrics to JSON file")
    return parser.parse_args()

def load_frames(file_patterns):
    file_list = []
    for pat in file_patterns:
        # Check if pat is glob or direct file
        matched = sorted(glob.glob(pat))
        if matched:
            file_list.extend(matched)
        elif os.path.isfile(pat):
            file_list.append(pat)

    # Deduplicate while preserving order
    seen = set()
    files = []
    for f in file_list:
        if f not in seen:
            seen.add(f)
            files.append(f)

    if not files:
        print("Error: no matching .rgb565 files found", file=sys.stderr)
        sys.exit(1)

    r_list, g_list, b_list = [], [], []
    for f in files:
        if os.path.getsize(f) < FRAME_BYTES:
            print(f"Warning: file {f} size smaller than frame size, skipping", file=sys.stderr)
            continue
        raw = np.fromfile(f, dtype="<u2", count=FRAME_PIXELS).reshape((HEIGHT, WIDTH))
        # RB_SWAP=1:
        # bit[4:0] = R
        # bit[10:5] = G
        # bit[15:11] = B
        # Linear expansion to 0-255: R*255/31, G*255/63, B*255/31
        r = (raw & 0x001F) * (255.0 / 31.0)
        g = ((raw >> 5) & 0x003F) * (255.0 / 63.0)
        b = ((raw >> 11) & 0x001F) * (255.0 / 31.0)
        r_list.append(r)
        g_list.append(g)
        b_list.append(b)

    if not r_list:
        print("Error: no valid frames loaded", file=sys.stderr)
        sys.exit(1)

    R = np.stack(r_list, axis=0)
    G = np.stack(g_list, axis=0)
    B = np.stack(b_list, axis=0)
    return files, R, G, B

def compute_metrics(R, G, B, roi=None):
    """Compute all quality and noise metrics from R, G, B frame arrays (T, H, W)."""
    num_frames = R.shape[0]

    # Y = 0.299R + 0.587G + 0.114B
    Y = 0.299 * R + 0.587 * G + 0.114 * B

    # 1. Full image statistics
    mean_R_all = float(np.mean(R))
    mean_G_all = float(np.mean(G))
    mean_B_all = float(np.mean(B))
    gw_rg = mean_R_all / mean_G_all if mean_G_all > 0 else 0.0
    gw_bg = mean_B_all / mean_G_all if mean_G_all > 0 else 0.0

    # 2. Time-average map
    T_R = np.mean(R, axis=0)
    T_G = np.mean(G, axis=0)
    T_B = np.mean(B, axis=0)
    T_Y = np.mean(Y, axis=0)

    # 3. White reference area
    if roi:
        if isinstance(roi, str):
            coords = [int(c.strip()) for c in roi.split(",")]
        else:
            coords = list(roi)
        if len(coords) != 4:
            raise ValueError("--roi must be x0,y0,x1,y1")
        x0, y0, x1, y1 = coords
        roi_mask = np.zeros((HEIGHT, WIDTH), dtype=bool)
        roi_mask[y0:y1, x0:x1] = True
        white_pixels_count = int(np.sum(roi_mask))
        white_mode = f"ROI [{x0},{y0},{x1},{y1}]"
        w_R = float(np.mean(T_R[roi_mask])) if white_pixels_count > 0 else 0.0
        w_G = float(np.mean(T_G[roi_mask])) if white_pixels_count > 0 else 0.0
        w_B = float(np.mean(T_B[roi_mask])) if white_pixels_count > 0 else 0.0
    else:
        # Auto: T_Y in [150, 240] and max(R,G,B) - min(R,G,B) < 60
        chroma_diff = np.maximum.reduce([T_R, T_G, T_B]) - np.minimum.reduce([T_R, T_G, T_B])
        white_mask = (T_Y >= 150.0) & (T_Y <= 240.0) & (chroma_diff < 60.0)
        white_pixels_count = int(np.sum(white_mask))
        white_mode = "Auto (Y in [150,240], max-min<60)"
        w_R = float(np.mean(T_R[white_mask])) if white_pixels_count > 0 else 0.0
        w_G = float(np.mean(T_G[white_mask])) if white_pixels_count > 0 else 0.0
        w_B = float(np.mean(T_B[white_mask])) if white_pixels_count > 0 else 0.0

    white_rg = w_R / w_G if w_G > 0 else 0.0
    white_bg = w_B / w_G if w_G > 0 else 0.0

    # 4. Y mean and frame flicker
    mean_Y_all = float(np.mean(Y))
    frame_y_means = np.mean(Y, axis=(1, 2))
    frame_flicker = float(np.std(frame_y_means))

    # 5. Pixel temporal noise: mean of standard deviation across frames
    pix_std_Y = np.std(Y, axis=0)
    pix_std_R = np.std(R, axis=0)
    pix_std_G = np.std(G, axis=0)
    pix_std_B = np.std(B, axis=0)
    pix_noise_Y = float(np.mean(pix_std_Y))
    pix_noise_R = float(np.mean(pix_std_R))
    pix_noise_G = float(np.mean(pix_std_G))
    pix_noise_B = float(np.mean(pix_std_B))

    # 6. Row noise: dev = Y - T_Y, row mean of dev, then std of row means
    dev = Y - T_Y
    row_means_all = np.mean(dev, axis=2)  # shape (num_frames, HEIGHT)
    row_noise_full = float(np.std(row_means_all))
    expected_row_noise = pix_noise_Y / math.sqrt(WIDTH)
    row_ratio_full = row_noise_full / expected_row_noise if expected_row_noise > 0 else 0.0

    # 7. Dark area statistics: T_Y in [30, 100]
    dark_mask = (T_Y >= 30.0) & (T_Y <= 100.0)
    dark_pixels_count = int(np.sum(dark_mask))
    if dark_pixels_count > 0:
        dark_pix_noise_Y = float(np.mean(pix_std_Y[dark_mask]))
        dark_pix_noise_R = float(np.mean(pix_std_R[dark_mask]))
        dark_pix_noise_G = float(np.mean(pix_std_G[dark_mask]))
        dark_pix_noise_B = float(np.mean(pix_std_B[dark_mask]))

        # Row noise on masked pixels only
        counts_per_row = np.sum(dark_mask, axis=1)
        dark_row_means = []
        for t in range(num_frames):
            for h in range(HEIGHT):
                if counts_per_row[h] > 0:
                    dark_row_means.append(np.mean(dev[t, h, dark_mask[h]]))
        dark_row_noise = float(np.std(dark_row_means)) if dark_row_means else 0.0
        avg_cols_dark = float(np.mean(counts_per_row[counts_per_row > 0])) if np.any(counts_per_row > 0) else WIDTH
        expected_dark_row_noise = dark_pix_noise_Y / math.sqrt(avg_cols_dark) if avg_cols_dark > 0 else 0.0
        dark_row_ratio = dark_row_noise / expected_dark_row_noise if expected_dark_row_noise > 0 else 0.0
    else:
        dark_pix_noise_Y = 0.0
        dark_pix_noise_R = 0.0
        dark_pix_noise_G = 0.0
        dark_pix_noise_B = 0.0
        dark_row_noise = 0.0
        dark_row_ratio = 0.0

    res = {
        "num_frames": num_frames,
        "width": WIDTH,
        "height": HEIGHT,
        "full_mean_rgb": [mean_R_all, mean_G_all, mean_B_all],
        "full_gray_world": {"r_g": gw_rg, "b_g": gw_bg},
        "full_mean_y": mean_Y_all,
        "flicker_y_std": frame_flicker,
        "white_area": {
            "mode": white_mode,
            "pixel_count": white_pixels_count,
            "mean_rgb": [w_R, w_G, w_B],
            "r_g": white_rg,
            "b_g": white_bg,
        },
        "pixel_temporal_noise": {
            "y": pix_noise_Y,
            "r": pix_noise_R,
            "g": pix_noise_G,
            "b": pix_noise_B,
        },
        "row_noise": {
            "full_width_std": row_noise_full,
            "ratio_to_random": row_ratio_full,
            "expected_noise": expected_row_noise,
        },
        "dark_area": {
            "pixel_count": dark_pixels_count,
            "pixel_noise_y": dark_pix_noise_Y,
            "pixel_noise_rgb": [dark_pix_noise_R, dark_pix_noise_G, dark_pix_noise_B],
            "row_noise_std": dark_row_noise,
            "ratio_to_random": dark_row_ratio,
        }
    }
    return res

def print_metrics(res):
    num_frames = res["num_frames"]
    mean_R_all, mean_G_all, mean_B_all = res["full_mean_rgb"]
    gw_rg = res["full_gray_world"]["r_g"]
    gw_bg = res["full_gray_world"]["b_g"]
    mean_Y_all = res["full_mean_y"]
    frame_flicker = res["flicker_y_std"]

    white_mode = res["white_area"]["mode"]
    white_pixels_count = res["white_area"]["pixel_count"]
    w_R, w_G, w_B = res["white_area"]["mean_rgb"]
    white_rg = res["white_area"]["r_g"]
    white_bg = res["white_area"]["b_g"]

    pix_noise_Y = res["pixel_temporal_noise"]["y"]
    pix_noise_R = res["pixel_temporal_noise"]["r"]
    pix_noise_G = res["pixel_temporal_noise"]["g"]
    pix_noise_B = res["pixel_temporal_noise"]["b"]

    row_noise_full = res["row_noise"]["full_width_std"]
    row_ratio_full = res["row_noise"]["ratio_to_random"]
    expected_row_noise = res["row_noise"]["expected_noise"]

    dark_pixels_count = res["dark_area"]["pixel_count"]
    dark_pix_noise_Y = res["dark_area"]["pixel_noise_y"]
    dark_pix_noise_R, dark_pix_noise_G, dark_pix_noise_B = res["dark_area"]["pixel_noise_rgb"]
    dark_row_noise = res["dark_area"]["row_noise_std"]
    dark_row_ratio = res["dark_area"]["ratio_to_random"]

    print("=" * 60)
    print("FCAM Raw RGB565 Image Quality and Noise Analysis")
    print("=" * 60)
    print(f"Frames analyzed        : {num_frames}")
    print(f"Resolution             : {WIDTH}x{HEIGHT}")
    print("-" * 60)
    print(f"Full image Mean RGB    : R={mean_R_all:.2f}, G={mean_G_all:.2f}, B={mean_B_all:.2f}")
    print(f"Full image Gray-World  : R/G={gw_rg:.3f}, B/G={gw_bg:.3f}")
    print(f"Full image Mean Y      : {mean_Y_all:.2f}")
    print(f"Frame Y Std (Flicker)  : {frame_flicker:.4f}")
    print("-" * 60)
    print(f"White reference area   : {white_mode}")
    print(f"White pixels count     : {white_pixels_count}")
    print(f"White Mean RGB         : R={w_R:.2f}, G={w_G:.2f}, B={w_B:.2f}")
    print(f"White Balance ratio    : R/G={white_rg:.3f}, B/G={white_bg:.3f}")
    print("-" * 60)
    print("Pixel Temporal Noise (Std across frames):")
    print(f"  Y                    : {pix_noise_Y:.3f}")
    print(f"  R                    : {pix_noise_R:.3f}")
    print(f"  G                    : {pix_noise_G:.3f}")
    print(f"  B                    : {pix_noise_B:.3f}")
    print("-" * 60)
    print("Row Noise (Full Width):")
    print(f"  Row Noise (Std)      : {row_noise_full:.3f}")
    print(f"  Ratio to Pix / sqrt(W): {row_ratio_full:.2f}x (row_noise / {expected_row_noise:.3f})")
    print("-" * 60)
    print("Dark Area Analysis (Y in [30, 100]):")
    print(f"  Dark pixels count    : {dark_pixels_count} ({dark_pixels_count/FRAME_PIXELS*100:.1f}%)")
    print(f"  Dark Pixel Noise Y   : {dark_pix_noise_Y:.3f}")
    print(f"  Dark Pixel Noise RGB : R={dark_pix_noise_R:.3f}, G={dark_pix_noise_G:.3f}, B={dark_pix_noise_B:.3f}")
    print(f"  Dark Row Noise (Std) : {dark_row_noise:.3f}")
    print(f"  Dark Ratio to Pix / sqrt(W): {dark_row_ratio:.2f}x")
    print("=" * 60)

def main():
    args = parse_args()
    files, R, G, B = load_frames(args.inputs)

    # Export PNG if requested
    if args.png:
        r0 = np.clip(np.round(R[0]), 0, 255).astype(np.uint8)
        g0 = np.clip(np.round(G[0]), 0, 255).astype(np.uint8)
        b0 = np.clip(np.round(B[0]), 0, 255).astype(np.uint8)
        rgb0 = np.stack([r0, g0, b0], axis=-1)
        img = Image.fromarray(rgb0, "RGB")
        out_dir = os.path.dirname(args.png)
        if out_dir and not os.path.exists(out_dir):
            os.makedirs(out_dir, exist_ok=True)
        img.save(args.png)

    res = compute_metrics(R, G, B, roi=args.roi)
    print_metrics(res)

    if args.json_out:
        out_dir = os.path.dirname(args.json_out)
        if out_dir and not os.path.exists(out_dir):
            os.makedirs(out_dir, exist_ok=True)
        with open(args.json_out, "w", encoding="utf-8") as jf:
            json.dump(res, jf, indent=2, ensure_ascii=False)
        print(f"Exported metrics to {args.json_out}")

if __name__ == "__main__":
    main()
