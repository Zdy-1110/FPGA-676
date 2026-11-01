#!/usr/bin/env python3
"""
gen_case4_data.py
Generates 3 non-uniform test frames (64x8 = 512 pixels each) for Case 4 in tb_rt_night.v.
Computes exact mean Y = (R + 2*G + B) // 4, mean = round(sum(Y) / 512).
Outputs:
  case4_data.txt: 3 * 512 lines of "R G B"
  case4_expected.txt: 3 lines of expected mean
"""

import os

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    w = 64
    h = 8
    n = w * h

    frames = []

    # Frame 0: Gradient
    f0 = []
    for y in range(h):
        for x in range(w):
            r = (x * 4 + y * 16) & 0xFF
            g = (x * 3 + y * 24 + 10) & 0xFF
            b = (x * 5 + y * 8 + 30) & 0xFF
            f0.append((r, g, b))
    frames.append(f0)

    # Frame 1: High contrast blocks (checkerboard)
    f1 = []
    for y in range(h):
        for x in range(w):
            if ((x // 8) + (y // 2)) % 2 == 0:
                r, g, b = 220, 210, 200
            else:
                r, g, b = 20, 30, 25
            f1.append((r, g, b))
    frames.append(f1)

    # Frame 2: Pseudo-random hash pattern
    f2 = []
    state = 0x12345678
    for i in range(n):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        r = (state >> 16) & 0xFF
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        g = (state >> 16) & 0xFF
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        b = (state >> 16) & 0xFF
        f2.append((r, g, b))
    frames.append(f2)

    # Calculate expected means
    expected_means = []
    with open(os.path.join(script_dir, "case4_data.txt"), "w", encoding="utf-8") as f_data:
        for f_idx, f in enumerate(frames):
            y_sum = 0
            for r, g, b in f:
                y = (r + 2 * g + b) // 4
                y_sum += y
                f_data.write(f"{r} {g} {b}\n")
            mean_exact = y_sum / float(n)
            mean_round = round(mean_exact)
            expected_means.append(mean_round)
            print(f"Frame {f_idx}: sum={y_sum}, exact={mean_exact:.4f}, expected_mean={mean_round}")

    with open(os.path.join(script_dir, "case4_expected.txt"), "w", encoding="utf-8") as f_exp:
        for m in expected_means:
            f_exp.write(f"{m}\n")

    print("Generated case4_data.txt and case4_expected.txt successfully.")

if __name__ == "__main__":
    main()
