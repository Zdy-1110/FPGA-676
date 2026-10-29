import argparse
import json
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from video_io import iter_frames
from lane_bev import LaneBEV


DEFAULT_PARAMS = r"E:\Project\nesai2026\tools\ref_algo\params.json"
DEFAULT_FFMPEG = r"D:\Program Files\FormatFactory\ffmpeg.exe"


def recompute_y_top(vp_y, y_bot, H, p_lane):
    y_top = int(vp_y + max(0.04 * H, p_lane["roi_skip_frac"] * (y_bot - vp_y)))
    if y_bot - y_top < p_lane["roi_min_h_frac"] * H:
        y_top = y_bot - int(p_lane["roi_min_h_frac"] * H)
    if y_top < 0:
        y_top = 0
    return y_top


def x_at_y(pt0, pt1, y):
    x0, y0 = float(pt0[0]), float(pt0[1])
    x1, y1 = float(pt1[0]), float(pt1[1])
    if abs(y1 - y0) < 1e-9:
        return x0
    return x0 + (y - y0) * (x1 - x0) / (y1 - y0)


def parse_vp(text):
    parts = [float(v) for v in str(text).split(",")]
    if len(parts) != 2:
        raise ValueError("--vp-init must be 'x,y'")
    return parts


def draw_tile(frame, t, final_vp, y_bot, y_top, xbl, xbr):
    img = frame.copy()
    H, W = img.shape[:2]
    fvx, fvy = final_vp
    cv2.line(img, (int(round(xbl)), int(y_bot)), (int(fvx), int(fvy)),
             (0, 255, 0), 3)
    cv2.line(img, (int(round(xbr)), int(y_bot)), (int(fvx), int(fvy)),
             (255, 255, 0), 3)
    cv2.circle(img, (int(fvx), int(fvy)), 8, (0, 0, 255), -1)
    cv2.line(img, (0, int(y_bot)), (W - 1, int(y_bot)), (0, 255, 255), 2)
    cv2.line(img, (0, int(y_top)), (W - 1, int(y_top)), (128, 128, 128), 2)
    txt = f"t={t:.1f} VP({int(fvx)},{int(fvy)})"
    cv2.putText(img, txt, (10, 40), cv2.FONT_HERSHEY_SIMPLEX, 2.0,
                (0, 0, 0), 6, cv2.LINE_AA)
    cv2.putText(img, txt, (10, 40), cv2.FONT_HERSHEY_SIMPLEX, 2.0,
                (255, 255, 255), 2, cv2.LINE_AA)
    return cv2.resize(img, (960, 540), interpolation=cv2.INTER_AREA)


def make_sheet(frames, last_valid, final_vp, y_bot, y_top, out_path):
    n = len(last_valid)
    canvas = np.zeros((1080, 1920, 3), dtype=np.uint8)
    if n == 0:
        cv2.imwrite(out_path, canvas, [cv2.IMWRITE_JPEG_QUALITY, 85])
        return
    if n >= 4:
        idxs = [int(round(i * (n - 1) / 3.0)) for i in range(4)]
    else:
        idxs = list(range(n))
    seen = []
    for i in idxs:
        if i not in seen:
            seen.append(i)
    for k, i in enumerate(seen[:4]):
        entry = last_valid[i]
        buf_idx, t, _, _, xbl, xbr = entry
        tile = draw_tile(frames[buf_idx], t, final_vp, y_bot, y_top, xbl, xbr)
        r = k // 2
        c = k % 2
        canvas[r * 540:(r + 1) * 540, c * 960:(c + 1) * 960] = tile
    cv2.imwrite(out_path, canvas, [cv2.IMWRITE_JPEG_QUALITY, 85])


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--params", default=DEFAULT_PARAMS)
    ap.add_argument("--vp-init", required=True)
    ap.add_argument("--y-bot", type=int, required=True)
    ap.add_argument("--t0", type=float, default=0.0)
    ap.add_argument("--t1", type=float, default=10.0)
    ap.add_argument("--iters", type=int, default=4)
    ap.add_argument("--min-hits", type=int, default=6)
    ap.add_argument("--ffmpeg", default=DEFAULT_FFMPEG)
    args = ap.parse_args(argv)

    with open(args.params, "r", encoding="utf-8") as f:
        params = json.load(f)

    step = int(params["proc"]["step"])
    fps = 30.0
    fps_eff = fps / step
    vp_init = parse_vp(args.vp_init)
    W, H = 1920, 1080

    frames = []
    times = []
    gen = iter_frames(args.video, args.ffmpeg, step, args.t1, fps, W, H)
    for _, t, frame in gen:
        if t < args.t0:
            continue
        if t >= args.t1:
            break
        frames.append(frame)
        times.append(t)

    lane = LaneBEV(params["lane"], params["bev"], fps_eff, W, H)
    if frames:
        n_calib = min(len(frames), int(params["lane"]["calib_frames"]))
        lane.calibrate(frames[:n_calib])

    lane.y_bot = int(args.y_bot)
    lane.vp_x = float(vp_init[0])
    lane.vp_y = float(vp_init[1])
    lane.vp_frozen = True
    lane.y_top = recompute_y_top(lane.vp_y, lane.y_bot, H, params["lane"])
    lane.M = None
    lane._build_homography()

    inset0 = bool(params["bev"].get("inset", False))
    params["bev"]["inset"] = False

    bh = int(params["bev"]["h"])
    iters_records = []
    converged = False
    insufficient = False
    cur_vp = [lane.vp_x, lane.vp_y]
    last_valid = []
    vx = vy = float("nan")
    iqx = iqy = float("nan")

    for k in range(1, max(1, int(args.iters)) + 1):
        lane._reset_track_state()
        lane.vp_frozen = True
        lane.M = None
        lane._build_homography()

        valid = []
        for idx, f in enumerate(frames):
            lane.detect(f)
            ll = lane._last_lines["left"]
            rl = lane._last_lines["right"]
            hl = lane._last_hits["left"]
            hr = lane._last_hits["right"]
            if ll is None or rl is None:
                continue
            if hl < args.min_hits or hr < args.min_hits:
                continue
            pl = np.array([[ll[0] * (bh - 1) + ll[1], bh - 1], [ll[1], 0]],
                          dtype=np.float64)
            pr = np.array([[rl[0] * (bh - 1) + rl[1], bh - 1], [rl[1], 0]],
                          dtype=np.float64)
            il = lane._bev_to_img(pl)
            ir = lane._bev_to_img(pr)
            X = lane._line_inter(il[0], il[1], ir[0], ir[1])
            if X is None:
                continue
            ix, iy = X
            if not (0.0 <= ix < W and 0.0 <= iy < H):
                continue
            xbl = x_at_y(il[0], il[1], lane.y_bot)
            xbr = x_at_y(ir[0], ir[1], lane.y_bot)
            valid.append((idx, times[idx], float(ix), float(iy),
                          float(xbl), float(xbr)))

        n = len(valid)
        if n > 0:
            xs = np.array([v[2] for v in valid], dtype=np.float64)
            ys = np.array([v[3] for v in valid], dtype=np.float64)
            vx = float(np.median(xs))
            vy = float(np.median(ys))
            iqx = float(np.percentile(xs, 75) - np.percentile(xs, 25))
            iqy = float(np.percentile(ys, 75) - np.percentile(ys, 25))
        else:
            vx, vy = cur_vp[0], cur_vp[1]
            iqx = iqy = float("nan")

        iters_records.append({"vp_in": [cur_vp[0], cur_vp[1]], "n": n,
                              "vp_out": [vx, vy],
                              "iqr_x": iqx, "iqr_y": iqy})
        last_valid = valid

        if n < 10:
            insufficient = True
            break
        if abs(vx - cur_vp[0]) < 5.0 and abs(vy - cur_vp[1]) < 5.0:
            converged = True
            break
        cur_vp = [vx, vy]
        lane.vp_x = vx
        lane.vp_y = vy
        lane.y_top = recompute_y_top(vy, lane.y_bot, H, params["lane"])

    params["bev"]["inset"] = inset0

    final_vp = [int(round(vx)), int(round(vy))]
    final_y_top = recompute_y_top(final_vp[1], lane.y_bot, H, params["lane"])

    os.makedirs(args.out_dir, exist_ok=True)
    out = {"video": args.video, "t0": args.t0, "t1": args.t1,
           "y_bot": int(args.y_bot), "vp_init": [vp_init[0], vp_init[1]],
           "iters": iters_records, "final_vp": final_vp,
           "converged": bool(converged), "insufficient": bool(insufficient),
           "final_y_top": int(final_y_top)}
    with open(os.path.join(args.out_dir, "vp_measure.json"), "w",
              encoding="utf-8") as f:
        json.dump(out, f, indent=2)

    make_sheet(frames, last_valid, final_vp, int(args.y_bot), final_y_top,
               os.path.join(args.out_dir, "vpm_sheet.jpg"))

    print(f"final_vp: {final_vp}")
    print(f"converged: {converged}  insufficient: {insufficient}")
    for i, r in enumerate(iters_records, 1):
        print(f"  iter {i}: n={r['n']} vp_out=({r['vp_out'][0]:.1f},"
              f"{r['vp_out'][1]:.1f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
