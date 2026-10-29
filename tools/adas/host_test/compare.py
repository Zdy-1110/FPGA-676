#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse
import csv
import os
import sys

VIDEOS = ["112454", "112507", "112739", "113343", "113421", "113452", "113539"]

def load_csv(path):
    rows = {}
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            try:
                frame = int(r["frame"])
                rows[frame] = r
            except (ValueError, KeyError):
                continue
    return rows

def main():
    parser = argparse.ArgumentParser(description="Compare C and Python states.csv")
    parser.add_argument("--c-dir", default=r"E:/Project/nesai2026/tools/adas/host_test/out")
    parser.add_argument("--py-dir", default=r"E:/Project/nesai2026/video_review/ref_runs/E_r45")
    args = parser.parse_args()

    total_frames = 0
    total_raw_match = 0
    total_sig_match = 0

    all_raw_mismatches = []
    all_sig_mismatches = []

    print(f"{'Video':<10} | {'Frames':<8} | {'Raw Match':<10} | {'Raw Acc':<10} | {'Sig Match':<10} | {'Sig Acc':<10}")
    print("-" * 75)

    for vid in VIDEOS:
        c_csv = os.path.join(args.c_dir, vid, "states.csv")
        py_csv = os.path.join(args.py_dir, vid, "states.csv")

        c_rows = load_csv(c_csv)
        py_rows = load_csv(py_csv)

        frames = sorted(set(c_rows.keys()) & set(py_rows.keys()))
        n = len(frames)
        total_frames += n

        raw_match = 0
        sig_match = 0

        for f in frames:
            cr = c_rows[f]
            pr = py_rows[f]

            c_raw = (cr["raw_left"], cr["raw_straight"], cr["raw_right"])
            p_raw = (pr["raw_left"], pr["raw_straight"], pr["raw_right"])

            c_sig = (cr["sig_left"], cr["sig_straight"], cr["sig_right"])
            p_sig = (pr["sig_left"], pr["sig_straight"], pr["sig_right"])

            if c_raw == p_raw:
                raw_match += 1
            else:
                all_raw_mismatches.append((vid, f, cr.get("t", ""), c_raw, p_raw))

            if c_sig == p_sig:
                sig_match += 1
            else:
                all_sig_mismatches.append((vid, f, cr.get("t", ""), c_sig, p_sig))

        total_raw_match += raw_match
        total_sig_match += sig_match

        raw_pct = f"{100.0 * raw_match / n:.2f}%" if n > 0 else "N/A"
        sig_pct = f"{100.0 * sig_match / n:.2f}%" if n > 0 else "N/A"

        print(f"{vid:<10} | {n:<8} | {raw_match:<10} | {raw_pct:<10} | {sig_match:<10} | {sig_pct:<10}")

    print("-" * 75)
    tot_raw_pct = f"{100.0 * total_raw_match / total_frames:.2f}%" if total_frames > 0 else "N/A"
    tot_sig_pct = f"{100.0 * total_sig_match / total_frames:.2f}%" if total_frames > 0 else "N/A"
    print(f"{'Total':<10} | {total_frames:<8} | {total_raw_match:<10} | {tot_raw_pct:<10} | {total_sig_match:<10} | {tot_sig_pct:<10}")
    print()

    if all_sig_mismatches:
        print(f"Top {min(20, len(all_sig_mismatches))} SIG Mismatches (video, frame, t, C (L,S,R), Py (L,S,R)):")
        for m in all_sig_mismatches[:20]:
            print(f"  vid={m[0]} f={m[1]} t={m[2]}: C={m[3]} vs Py={m[4]}")
    else:
        print("All SIG match 100%!")

    if all_raw_mismatches:
        print(f"\nTop {min(20, len(all_raw_mismatches))} RAW Mismatches (video, frame, t, C (L,S,R), Py (L,S,R)):")
        for m in all_raw_mismatches[:20]:
            print(f"  vid={m[0]} f={m[1]} t={m[2]}: C={m[3]} vs Py={m[4]}")
    else:
        print("All RAW match 100%!")

    return 0

if __name__ == "__main__":
    sys.exit(main())
