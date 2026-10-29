import argparse
import csv
import itertools
import json
import os
import subprocess
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from video_io import iter_frames, video_id
from tl_ref import TLDetector, TLFilter, associate
from lane_ref import LaneDetector
from lane_bev import LaneBEV
from motion_ref import EgoMotion


DEFAULT_PARAMS = r"E:\Project\nesai2026\tools\ref_algo\params.json"
DEFAULT_FFMPEG = r"D:\Program Files\FormatFactory\ffmpeg.exe"

COLOR_BGR = {"red": (0, 0, 255), "yellow": (0, 255, 255), "green": (0, 255, 0)}
SHAPE_LETTER = {"round": "R", "left": "L", "straight": "S",
                "right": "T", "unknown": "U"}
CSV_COLS = ["frame", "t", "sig_left", "sig_straight", "sig_right",
            "raw_left", "raw_straight", "raw_right", "n_lights", "lights",
            "left_line", "right_line", "left_cov", "right_cov",
            "ego_motion", "motion_score"]
LANE_DBG_COLS = ["frame", "t", "fallback", "n_cands", "cands", "uL", "uR",
                 "d", "p", "score", "d_est", "p_est"]


def _fmt2(v):
    return "" if v is None else f"{float(v):.2f}"


def draw_overlay(frame, vid, i, t, sig, raw, lights, lane_res, state, score,
                 y_top, y_bot, vp_x=None, vp_y=None):
    img = frame.copy()
    H, W = img.shape[:2]
    for l in lights:
        col = COLOR_BGR.get(l["color"], (255, 255, 255))
        cv2.rectangle(img, (l["x1"], l["y1"]), (l["x2"], l["y2"]), col, 3)
        letter = SHAPE_LETTER.get(l["shape"], "U")
        cv2.putText(img, letter, (l["x1"], max(12, l["y1"] - 4)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, col, 2)
    cv2.line(img, (0, y_top), (W - 1, y_top), (128, 128, 128), 1)
    cv2.line(img, (0, y_bot), (W - 1, y_bot), (128, 128, 128), 1)
    for side, tkey in (("left", "left_line"), ("right", "right_line")):
        xb = lane_res.get(side + "_xb")
        xt = lane_res.get(side + "_xt")
        if xb is None or xt is None:
            continue
        typ = lane_res[tkey]
        if typ == "none":
            continue
        col = (0, 255, 0) if typ.endswith("dashed") else (0, 0, 255)
        cv2.line(img, (int(xb), y_bot), (int(xt), y_top), col, 4)

    if vp_x is not None and vp_y is not None:
        cv2.circle(img, (int(vp_x), int(vp_y)), 10, (255, 255, 0), -1)

    ov = img.copy()
    cv2.rectangle(ov, (0, 0), (760, 116), (0, 0, 0), -1)
    cv2.addWeighted(ov, 0.5, img, 0.5, 0, img)
    lines = [
        f"{vid} t={t:.1f} f={i}",
        f"SIG L:{sig[0]} S:{sig[1]} R:{sig[2]}  raw L:{raw[0]} S:{raw[1]} R:{raw[2]}",
        f"LINE left:{lane_res['left_line']} {lane_res['left_cov']:.2f}  "
        f"right:{lane_res['right_line']} {lane_res['right_cov']:.2f}",
        f"EGO {state} {score:.2f} VP({int(vp_x)},{int(vp_y)})",
    ]
    for k, txt in enumerate(lines):
        cv2.putText(img, txt, (8, 24 + k * 26), cv2.FONT_HERSHEY_SIMPLEX,
                    0.62, (255, 255, 255), 1, cv2.LINE_AA)

    bev = lane_res.get("bev_img")
    if bev is not None:
        bs = cv2.resize(bev, (400, 400), interpolation=cv2.INTER_NEAREST)
        x0 = W - 10 - 400
        y0 = 10
        img[y0:y0 + 400, x0:x0 + 400] = bs
        cv2.rectangle(img, (x0 - 2, y0 - 2), (x0 + 402, y0 + 402),
                      (255, 255, 255), 2)
    return img


def process_video(video, out_dir, params_path=DEFAULT_PARAMS, step=None,
                  ffmpeg=DEFAULT_FFMPEG, snap_every=2.0, save_video=False,
                  max_seconds=0.0, quiet=False, roi=None, lane_method=None):
    with open(params_path, "r", encoding="utf-8") as f:
        params = json.load(f)
    if step is None:
        step = int(params["proc"]["step"])
    step = int(step)
    fps = 30.0
    fps_eff = fps / step
    W, H = 1920, 1080
    vid = video_id(video)

    os.makedirs(out_dir, exist_ok=True)
    snaps_dir = os.path.join(out_dir, "snaps")
    os.makedirs(snaps_dir, exist_ok=True)

    gen = iter_frames(video, ffmpeg, step, max_seconds, fps, W, H)
    buf = []
    calib_frames_n = int(params["lane"]["calib_frames"])
    if params.get("bev", {}).get("vp_search", False):
        calib_frames_n = max(calib_frames_n,
                             int(params["bev"].get("vps_fine_frames", 24)),
                             int(params["bev"].get("vpcl_frames", 0)))
    for item in gen:
        buf.append(item)
        if len(buf) >= calib_frames_n:
            break

    method = lane_method if lane_method else params["lane"].get(
        "method", "hough")
    if method not in ("hough", "bev"):
        method = "hough"
    if method == "bev":
        lane = LaneBEV(params["lane"], params["bev"], fps_eff, W, H)
    else:
        lane = LaneDetector(params["lane"], fps_eff, W, H)
    if buf:
        calib = lane.calibrate([f for _, _, f in buf])
    else:
        calib = {"dash_y": H - 1, "y_top": 0, "y_bot": H - 1,
                 "vp_x": W / 2.0, "vp_y": H / 2.0, "vp_ok": False,
                 "votes": 0.0}
    vps_debug_img = getattr(lane, "vps_debug_img", None)
    if vps_debug_img is not None:
        cv2.imwrite(os.path.join(out_dir, "vps_debug.jpg"), vps_debug_img,
                    [cv2.IMWRITE_JPEG_QUALITY, 85])
    roi_override = False
    if roi is not None:
        parts = [int(v) for v in str(roi).split(",")]
        if len(parts) not in (2, 4):
            raise ValueError("--roi must be 'y_top,y_bot' or 'y_top,y_bot,vp_x,vp_y'")
        calib["y_top"], calib["y_bot"] = parts[:2]
        lane.y_top, lane.y_bot = parts[:2]
        if len(parts) == 4:  # 人工指定消失点，并冻结慢速更新
            calib["vp_x"], calib["vp_y"] = parts[2:]
            lane.vp_x, lane.vp_y = float(parts[2]), float(parts[3])
            # refine_after_manual 为真时人工值只作初值，之后仍按两条自车车道线交点自校正
            lane.vp_frozen = not params.get("bev", {}).get("refine_after_manual", False)
        roi_override = True
    with open(os.path.join(out_dir, "calib.json"), "w", encoding="utf-8") as f:
        out = dict(calib)
        out["step"] = step
        out["fps_eff"] = fps_eff
        out["roi_override"] = roi_override
        out["lane_method"] = method
        json.dump(out, f, indent=2)

    tl = TLDetector(params["tl"])
    filt = TLFilter(params["tl"], fps_eff)
    motion = EgoMotion(params["motion"], roi_rows=(calib["y_top"], calib["y_bot"]))

    vw = None
    vpath = os.path.join(out_dir, f"{vid}_ref.mp4")
    if save_video:
        cmd = [ffmpeg, "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt",
               "bgr24", "-s", f"{W}x{H}", "-r", f"{fps_eff}", "-i", "-",
               "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
               "-pix_fmt", "yuv420p", vpath]
        vw = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)

    csv_path = os.path.join(out_dir, "states.csv")
    dbg_path = os.path.join(out_dir, "lane_debug.csv")
    dbg_fh = None
    dbg_wr = None
    n_done = 0
    sum_tl = sum_lane = sum_motion = 0.0
    sum_all = 0.0
    saved_snaps = set()
    t_start = time.perf_counter()
    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        wr = csv.writer(fh)
        wr.writerow(CSV_COLS)
        for i, t, frame in itertools.chain(buf, gen):
            ts0 = time.perf_counter()

            a = time.perf_counter()
            state, score = motion.update(frame)
            sum_motion += time.perf_counter() - a

            a = time.perf_counter()
            lights = tl.detect(frame)
            raw = associate(lights)
            sig = filt.update(raw, ego_stopped=(state == "stopped"))
            sum_tl += time.perf_counter() - a

            a = time.perf_counter()
            lane_res = lane.detect(frame)
            sum_lane += time.perf_counter() - a

            pd = lane_res.get("pair_dbg")
            if pd is not None:
                if dbg_wr is None:
                    dbg_fh = open(dbg_path, "w", newline="", encoding="utf-8")
                    dbg_wr = csv.writer(dbg_fh)
                    dbg_wr.writerow(LANE_DBG_COLS)
                dbg_wr.writerow([i, f"{t:.2f}", bool(pd.get("fallback")),
                                 pd.get("n_cands"), pd.get("cands") or "",
                                 _fmt2(pd.get("uL")), _fmt2(pd.get("uR")),
                                 _fmt2(pd.get("d")), _fmt2(pd.get("p")),
                                 _fmt2(pd.get("score")), _fmt2(pd.get("d_est")),
                                 _fmt2(pd.get("p_est"))])

            lights_str = ";".join(
                f"{l['color']}:{l['shape']}:{l['x1']}:{l['y1']}:{l['x2']}:{l['y2']}"
                for l in lights)
            wr.writerow([i, f"{t:.3f}", sig[0], sig[1], sig[2],
                         raw[0], raw[1], raw[2], len(lights), lights_str,
                         lane_res["left_line"], lane_res["right_line"],
                         f"{lane_res['left_cov']:.3f}",
                         f"{lane_res['right_cov']:.3f}", state, f"{score:.3f}"])

            need_snap = False
            if snap_every and snap_every > 0:
                k = int(round(t / snap_every))
                if abs(t - k * snap_every) <= 1e-6 and k not in saved_snaps:
                    saved_snaps.add(k)
                    need_snap = True
            if need_snap or vw is not None:
                img = draw_overlay(frame, vid, i, t, sig, raw, lights, lane_res,
                                   state, score, calib["y_top"], calib["y_bot"],
                                   lane.vp_x, lane.vp_y)
                if need_snap:
                    cv2.imwrite(os.path.join(snaps_dir, f"{vid}_t{t:05.1f}.jpg"),
                                img, [cv2.IMWRITE_JPEG_QUALITY, 85])
                if vw is not None:
                    vw.stdin.write(np.ascontiguousarray(img).tobytes())

            sum_all += time.perf_counter() - ts0
            n_done += 1

    if dbg_fh is not None:
        dbg_fh.close()

    if vw is not None:
        try:
            vw.stdin.close()
        except Exception:
            pass
        try:
            vw.wait(timeout=60)
        except Exception:
            try:
                vw.kill()
            except Exception:
                pass
        try:
            vw.stderr.close()
        except Exception:
            pass

    wall = time.perf_counter() - t_start
    if n_done == 0:
        n_done = 1
    stats = {"n": n_done, "wall_s": wall,
             "avg_ms": 1000.0 * sum_all / n_done,
             "tl_ms": 1000.0 * sum_tl / n_done,
             "lane_ms": 1000.0 * sum_lane / n_done,
             "motion_ms": 1000.0 * sum_motion / n_done,
             "out_dir": out_dir, "vid": vid}
    if not quiet:
        print(f"[{vid}] processed frames: {stats['n']}")
        print(f"[{vid}] avg per frame: {stats['avg_ms']:.1f} ms")
        print(f"[{vid}] avg module ms  tl: {stats['tl_ms']:.1f}  "
              f"lane: {stats['lane_ms']:.1f}  motion: {stats['motion_ms']:.1f}")
    return stats


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--params", default=DEFAULT_PARAMS)
    ap.add_argument("--step", type=int, default=None)
    ap.add_argument("--ffmpeg", default=DEFAULT_FFMPEG)
    ap.add_argument("--snap-every", type=float, default=2.0)
    ap.add_argument("--save-video", action="store_true")
    ap.add_argument("--max-seconds", type=float, default=0.0)
    ap.add_argument("--roi", default=None)
    ap.add_argument("--lane-method", choices=["hough", "bev"], default=None)
    args = ap.parse_args(argv)
    process_video(args.video, args.out_dir, args.params, args.step,
                  args.ffmpeg, args.snap_every, args.save_video,
                  args.max_seconds, roi=args.roi,
                  lane_method=args.lane_method)
    return 0


if __name__ == "__main__":
    sys.exit(main())
