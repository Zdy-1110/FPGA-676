"""Build a deterministic RKNN quantization calibration set from label_pool.

Run with the Windows yoloe-trt python (cv2 + numpy available).

    python tools/npu_convert/make_calib.py --profile band \
        --out models/npu/calib/band_960x320

Layout per profile (matches the ONNX sidecar annotations):
    band   : rows y in [360, 1000) of the 1920x1080 frame -> INTER_AREA 960x320
    mosaic : whole 1920x1080 frame                        -> INTER_AREA 640x384

Outputs, inside <out>:
    <video>__<stem>.png   lossless calibration images
    dataset.txt           one bare file name per line (relative to this dir)
    calib_meta.json       parameters, per-video allocation, file list
"""

import argparse
import json
import os
import sys

import numpy as np
import cv2

DEFAULT_EXCLUDE = [
    "video_20260929_111440",
    "video_20260929_113343",
    "video_20260929_113452",
    "video_20260929_112739",  # off-axis mount: band is mostly dashboard/screen
]

PROFILES = {
    "band": {"y0": 360, "y1": 1000, "width": 960, "height": 320},
    "mosaic": {"y0": None, "y1": None, "width": 640, "height": 384},
    "side": {"y0": 360, "y1": 1000, "width": 640, "height": 224},
}


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Build RKNN calibration set")
    ap.add_argument("--pool", default=os.path.join("video_review", "label_pool"))
    ap.add_argument("--profile", required=True, choices=sorted(PROFILES))
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--out", required=True)
    ap.add_argument("--exclude-videos", nargs="*", default=list(DEFAULT_EXCLUDE))
    ap.add_argument("--overwrite", action="store_true")
    return ap.parse_args(argv)


def list_videos(pool, exclude):
    excluded = set(exclude)
    videos = []
    for name in sorted(os.listdir(pool)):
        path = os.path.join(pool, name)
        if not os.path.isdir(path) or name in excluded:
            continue
        jpgs = sorted(f for f in os.listdir(path) if f.lower().endswith(".jpg"))
        if not jpgs:
            print("warn: %s has no .jpg, skipped" % name, file=sys.stderr)
            continue
        videos.append((name, path, jpgs))
    return videos


def allocate(videos, n):
    """Proportional allocation with largest remainder, min 1 per video."""
    if n < len(videos):
        raise ValueError("n=%d is smaller than the %d videos" % (n, len(videos)))
    total = sum(len(v[2]) for v in videos)
    quota = []
    base = {}
    for name, _path, jpgs in videos:
        q = float(n) * len(jpgs) / float(total)
        quota.append((name, q))
        base[name] = max(1, int(np.floor(q)))

    diff = n - sum(base.values())
    if diff > 0:
        order = sorted(quota, key=lambda kv: (-(kv[1] - np.floor(kv[1])), kv[0]))
        i = 0
        while diff > 0:
            base[order[i % len(order)][0]] += 1
            diff -= 1
            i += 1
    elif diff < 0:
        order = sorted(quota, key=lambda kv: (kv[1] - np.floor(kv[1]), -base[kv[0]], kv[0]))
        i = 0
        while diff < 0:
            name = order[i % len(order)][0]
            if base[name] > 1:
                base[name] -= 1
                diff += 1
            i += 1
    return base


def pick_indices(count, k):
    """k evenly spaced, reproducible indices in [0, count)."""
    idx = np.linspace(0, count - 1, k).round().astype(np.int64)
    if len(np.unique(idx)) != k:
        raise ValueError("linspace collision for count=%d k=%d" % (count, k))
    return idx.tolist()


def imread(path):
    buf = np.fromfile(path, dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if img is None:
        raise IOError("cv2.imdecode failed: %s" % path)
    return img


def imwrite_png(path, img):
    ok, buf = cv2.imencode(".png", img)
    if not ok:
        raise IOError("cv2.imencode failed: %s" % path)
    buf.tofile(path)


def prepare(img, profile):
    p = PROFILES[profile]
    if p["y0"] is not None:
        img = img[p["y0"]:p["y1"], :, :]
    size = (p["width"], p["height"])
    out = cv2.resize(img, size, interpolation=cv2.INTER_AREA)
    if out.shape != (p["height"], p["width"], 3):
        raise ValueError("unexpected shape %r for %s" % (out.shape, profile))
    return out


def main(argv=None):
    args = parse_args(argv)
    if args.n <= 0:
        print("error: --n must be positive", file=sys.stderr)
        return 2
    if not os.path.isdir(args.pool):
        print("error: pool not found: %s" % args.pool, file=sys.stderr)
        return 2
    if os.path.isdir(args.out) and os.listdir(args.out) and not args.overwrite:
        print("error: %s exists and is not empty (use --overwrite)" % args.out, file=sys.stderr)
        return 2

    videos = list_videos(args.pool, args.exclude_videos)
    if not videos:
        print("error: no usable video under %s" % args.pool, file=sys.stderr)
        return 2

    alloc = allocate(videos, args.n)
    os.makedirs(args.out, exist_ok=True)

    files = []
    per_video = {}
    for name, path, jpgs in videos:
        k = alloc[name]
        idx = pick_indices(len(jpgs), k)
        per_video[name] = k
        for i in idx:
            src = os.path.join(path, jpgs[i])
            stem = os.path.splitext(jpgs[i])[0]
            dst_name = "%s__%s.png" % (name, stem)
            img = prepare(imread(src), args.profile)
            imwrite_png(os.path.join(args.out, dst_name), img)
            files.append(dst_name)
        print("%-24s %4d images -> %3d picked" % (name, len(jpgs), k))

    if len(files) != args.n or len(set(files)) != args.n:
        print("error: produced %d files (%d unique), expected %d"
              % (len(files), len(set(files)), args.n), file=sys.stderr)
        return 3

    dataset_path = os.path.join(args.out, "dataset.txt")
    with open(dataset_path, "w", encoding="utf-8", newline="\n") as f:
        for name in files:
            f.write(name + "\n")

    meta = {
        "pool": os.path.abspath(args.pool),
        "profile": args.profile,
        "n": args.n,
        "out": os.path.abspath(args.out),
        "exclude_videos": list(args.exclude_videos),
        "input_size": [PROFILES[args.profile]["width"], PROFILES[args.profile]["height"]],
        "crop_y": [PROFILES[args.profile]["y0"], PROFILES[args.profile]["y1"]],
        "selection": "proportional largest-remainder, linspace within video",
        "per_video": per_video,
        "count": len(files),
        "files": files,
    }
    with open(os.path.join(args.out, "calib_meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    print("wrote %d images + dataset.txt + calib_meta.json -> %s"
          % (len(files), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
