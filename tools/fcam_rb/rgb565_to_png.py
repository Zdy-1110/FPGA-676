#!/usr/bin/env python3
"""
Convert FPGA front camera raw RGB565 (960x540) to standard PNG image.
Format: 960x540 RGB565 with RB_SWAP=1 (BGR565: R in [4:0], G in [10:5], B in [15:11]).
"""

import sys
import os
import argparse
import numpy as np
from PIL import Image

WIDTH = 960
HEIGHT = 540
FRAME_BYTES = WIDTH * HEIGHT * 2

def convert_file(input_path, output_path, swap_rb=False):
    if not os.path.isfile(input_path):
        print(f"Error: input file {input_path} does not exist", file=sys.stderr)
        return False

    size = os.path.getsize(input_path)
    if size < FRAME_BYTES:
        print(f"Error: file size {size} is less than frame size {FRAME_BYTES}", file=sys.stderr)
        return False

    raw = np.fromfile(input_path, dtype=np.uint16, count=WIDTH * HEIGHT)
    raw = raw.reshape((HEIGHT, WIDTH))

    # RB_SWAP=1 in FPGA display:
    # px[4:0]   -> Red
    # px[10:5]  -> Green
    # px[15:11] -> Blue
    if not swap_rb:
        r = ((raw & 0x001F) * 255 // 31).astype(np.uint8)
        g = (((raw >> 5) & 0x003F) * 255 // 63).astype(np.uint8)
        b = (((raw >> 11) & 0x001F) * 255 // 31).astype(np.uint8)
    else:
        # Standard RGB565 (R in [15:11], B in [4:0])
        r = (((raw >> 11) & 0x001F) * 255 // 31).astype(np.uint8)
        g = (((raw >> 5) & 0x003F) * 255 // 63).astype(np.uint8)
        b = ((raw & 0x001F) * 255 // 31).astype(np.uint8)

    rgb = np.stack([r, g, b], axis=-1)
    img = Image.fromarray(rgb, 'RGB')
    img.save(output_path)
    print(f"Converted: {input_path} -> {output_path} ({WIDTH}x{HEIGHT})")
    return True

def main():
    parser = argparse.ArgumentParser(description="Convert FPGA front camera .rgb565 to PNG")
    parser.add_argument("input", help="Input .rgb565 file or directory")
    parser.add_argument("output", nargs="?", help="Output .png file (optional)")
    parser.add_argument("--standard-rgb", action="store_true", help="Use standard RGB565 instead of BGR565")
    args = parser.parse_args()

    if os.path.isfile(args.input):
        out = args.output
        if not out:
            out = os.path.splitext(args.input)[0] + ".png"
        convert_file(args.input, out, args.standard_rgb)
    elif os.path.isdir(args.input):
        for fname in sorted(os.listdir(args.input)):
            if fname.endswith(".rgb565"):
                in_p = os.path.join(args.input, fname)
                out_p = os.path.join(args.input, os.path.splitext(fname)[0] + ".png")
                convert_file(in_p, out_p, args.standard_rgb)
    else:
        print(f"Error: {args.input} not found", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
