import argparse
import glob
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from video_io import video_id
from run_ref import process_video, DEFAULT_PARAMS, DEFAULT_FFMPEG

DEFAULT_SRC = r"E:\Project\nesai2026\video_review\src"
DEFAULT_OUT = r"E:\Project\nesai2026\video_review\ref_runs"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=DEFAULT_SRC)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--params", default=DEFAULT_PARAMS)
    ap.add_argument("--step", type=int, default=None)
    ap.add_argument("--save-video", action="store_true")
    args = ap.parse_args(argv)

    vids = sorted(glob.glob(os.path.join(args.src, "video_20260929_*.mp4")))
    summary = []
    for v in vids:
        vid = video_id(v)
        out_dir = os.path.join(args.out, vid)
        t0 = time.perf_counter()
        stats = process_video(v, out_dir, args.params, args.step,
                              DEFAULT_FFMPEG, 2.0, args.save_video, 0.0)
        dt = time.perf_counter() - t0
        summary.append((vid, stats["n"], dt))
        print(f"[{vid}] frames={stats['n']} elapsed={dt:.1f}s")
    print("---- summary ----")
    total_n = 0
    total_t = 0.0
    for vid, n, dt in summary:
        print(f"{vid}: frames={n} elapsed={dt:.1f}s")
        total_n += n
        total_t += dt
    print(f"total: videos={len(summary)} frames={total_n} elapsed={total_t:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
