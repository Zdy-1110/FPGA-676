#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse
import csv
import glob
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

THUMB_W, THUMB_H = 160, 90


def run_ffmpeg_extract(ffmpeg, video, fps, tmp_dir):
    pattern = os.path.join(tmp_dir, "%06d.jpg")
    cmd = [
        ffmpeg,
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-i", video,
        "-vf", "fps=%s" % fps,
        "-q:v", "2",
        "-start_number", "1",
        pattern,
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode("utf-8", errors="replace"))
        raise RuntimeError("ffmpeg failed for %s (exit %d)" % (video, proc.returncode))
    return sorted(glob.glob(os.path.join(tmp_dir, "*.jpg")))


def thumb_gray(path):
    with Image.open(path) as im:
        small = im.convert("L").resize((THUMB_W, THUMB_H), Image.BILINEAR)
    return np.asarray(small, dtype=np.float32)


def process_video(ffmpeg, video, out_root, fps, diff_thresh):
    stem = os.path.splitext(os.path.basename(video))[0]
    out_dir = os.path.join(out_root, stem)
    os.makedirs(out_dir, exist_ok=True)

    tmp_dir = tempfile.mkdtemp(prefix="vf_")
    try:
        frames = run_ffmpeg_extract(ffmpeg, video, fps, tmp_dir)
        extracted = len(frames)

        rows = []
        kept = 0
        prev_thumb = None
        for idx, fpath in enumerate(frames):
            t = idx / float(fps)
            thumb = thumb_gray(fpath)
            if prev_thumb is None:
                mad = ""
                keep = True
            else:
                mad = float(np.mean(np.abs(thumb - prev_thumb)))
                keep = mad >= diff_thresh
            if keep:
                fname = "%s_t%.2f.jpg" % (stem, t)
                dst = os.path.join(out_dir, fname)
                shutil.move(fpath, dst)
                rows.append((os.path.basename(video), fname, "%.2f" % t, mad))
                prev_thumb = thumb
                kept += 1
            else:
                os.remove(fpath)
        return extracted, kept, rows
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description="Extract and de-duplicate frames from videos.")
    ap.add_argument("--src", required=True, help="source directory")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--fps", type=float, default=2.0, help="extraction fps (default 2)")
    ap.add_argument("--ffmpeg", default="ffmpeg", help="path to ffmpeg executable")
    ap.add_argument("--diff", type=float, default=6.0, help="dedup threshold (default 6.0)")
    ap.add_argument("--glob", default="*.mp4", help="file glob (default *.mp4)")
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    out_root = os.path.abspath(args.out)
    os.makedirs(out_root, exist_ok=True)

    videos = sorted(glob.glob(os.path.join(src, args.glob)))
    if not videos:
        sys.stderr.write("no files match %s in %s\n" % (args.glob, src))
        return 1

    manifest_rows = []
    total_extracted = 0
    total_kept = 0
    for v in videos:
        extracted, kept, rows = process_video(args.ffmpeg, v, out_root, args.fps, args.diff)
        total_extracted += extracted
        total_kept += kept
        manifest_rows.extend(rows)
        print("%s: extracted=%d kept=%d" % (os.path.basename(v), extracted, kept))

    manifest_path = os.path.join(out_root, "manifest.csv")
    with open(manifest_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["video", "file", "time_s", "mean_abs_diff"])
        for r in manifest_rows:
            w.writerow(r)

    print("TOTAL: extracted=%d kept=%d manifest=%s" % (total_extracted, total_kept, manifest_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
