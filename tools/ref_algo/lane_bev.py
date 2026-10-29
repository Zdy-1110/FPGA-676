import math
import time
from collections import deque

import cv2
import numpy as np

from lane_ref import LaneDetector


class LaneBEV(LaneDetector):
    def __init__(self, params_lane, params_bev, fps_eff, W=1920, H=1080):
        super().__init__(params_lane, fps_eff, W, H)
        self.pb = params_bev
        self.ego_frac = params_lane.get("ego_x_frac", 0.5)
        self.bev_yt = None
        self.M = None
        self.Minv = None
        self._mat_vp = None
        self.prev_base = {"left": None, "right": None}
        self.prev_hits = {"left": 0, "right": 0}
        self.prev_done = {"left": False, "right": False}
        self.win_len = max(1, int(round(params_bev["win_s"] * fps_eff)))
        self.bev_win = {"left": deque(maxlen=self.win_len),
                        "right": deque(maxlen=self.win_len)}
        self.d_est = None
        self.p_est = params_bev["pair_p_init"]
        self.prev_pair = None
        self._last_lines = {"left": None, "right": None}
        self._last_hits = {"left": 0, "right": 0}

    def _marking(self, frame, y0, y1):
        p = self.p
        H, W = self.H, self.W
        y0 = max(0, min(int(y0), H))
        y1 = max(y0, min(int(y1), H))
        markings_full = np.zeros((H, W), dtype=np.uint8)
        yellow_full = np.zeros((H, W), dtype=np.uint8)
        if y1 <= y0:
            return markings_full, yellow_full
        roi = frame[y0:y1]
        g = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
        lm = cv2.blur(g.astype(np.float32), (int(p["tophat_win"]), 1))
        diff = g.astype(np.float32) - lm
        marking = (diff >= p["tophat_delta"]) & (g >= p["y_min"])
        hsv = cv2.cvtColor(roi, cv2.COLOR_BGR2HSV_FULL)
        hc = hsv[:, :, 0]
        sc = hsv[:, :, 1]
        yellow = (marking & (hc >= p["yellow_h_lo"])
                  & (hc <= p["yellow_h_hi"]) & (sc >= p["yellow_s_min"]))
        white = marking & (sc <= p["white_s_max"])
        markings = yellow | white
        markings_full[y0:y1] = markings.astype(np.uint8) * 255
        yellow_full[y0:y1] = yellow.astype(np.uint8) * 255
        return markings_full, yellow_full

    def _marking_bev(self, frame):
        p = self.p
        pb = self.pb
        w, h = int(pb["w"]), int(pb["h"])
        bev_bgr = cv2.warpPerspective(frame, self.M, (w, h),
                                      flags=cv2.INTER_LINEAR,
                                      borderMode=cv2.BORDER_CONSTANT,
                                      borderValue=0)
        G = cv2.cvtColor(bev_bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)
        hsv = cv2.cvtColor(bev_bgr, cv2.COLOR_BGR2HSV_FULL)
        hc = hsv[:, :, 0]
        sc = hsv[:, :, 1]
        d = int(pb["ridge_d"])
        Gl = np.full_like(G, 255.0)
        Gr = np.full_like(G, 255.0)
        if 0 < d < w:
            Gl[:, d:] = G[:, :w - d]
            Gr[:, :w - d] = G[:, d:]
        R = G - np.maximum(Gl, Gr)
        ridge = (R >= pb["ridge_delta"]) & (G >= p["y_min"])
        yellow = (ridge & (hc >= p["yellow_h_lo"]) & (hc <= p["yellow_h_hi"])
                  & (sc >= p["yellow_s_min"]))
        white = ridge & (sc <= p["white_s_max"])
        bev_m = yellow | white
        bev_y = yellow
        bev_gray = G.astype(np.uint8)
        return bev_m, bev_y, bev_gray

    def _build_homography(self):
        pb = self.pb
        W, H = self.W, self.H
        w, h = int(pb["w"]), int(pb["h"])
        yb = float(self.y_bot)
        vx, vy = self.vp_x, self.vp_y
        yt = vy + max(pb["min_skip_frac"] * H, pb["skip_frac"] * (yb - vy))
        if (yb - vy) == 0:
            s = 1.0
        else:
            s = (yt - vy) / (yb - vy)
        HS = pb["half_span_frac"] * W
        src = np.float32([[vx - HS, yb], [vx + HS, yb],
                          [vx - HS * s, yt], [vx + HS * s, yt]])
        dst = np.float32([[0, h - 1], [w - 1, h - 1],
                          [0, 0], [w - 1, 0]])
        self.M = cv2.getPerspectiveTransform(src, dst)
        self.Minv = np.linalg.inv(self.M)
        self.bev_yt = int(yt)
        self._mat_vp = (vx, vy)

    def _ridge_bev_with(self, frame, M, size):
        p = self.p
        pb = self.pb
        s = int(size)
        bev_bgr = cv2.warpPerspective(frame, M, (s, s),
                                      flags=cv2.INTER_LINEAR,
                                      borderMode=cv2.BORDER_CONSTANT,
                                      borderValue=0)
        G = cv2.cvtColor(bev_bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)
        hsv = cv2.cvtColor(bev_bgr, cv2.COLOR_BGR2HSV_FULL)
        hc = hsv[:, :, 0]
        sc = hsv[:, :, 1]
        d = max(1, int(round(pb["ridge_d"] * s / 400.0)))
        Gl = np.full_like(G, 255.0)
        Gr = np.full_like(G, 255.0)
        if 0 < d < s:
            Gl[:, d:] = G[:, :s - d]
            Gr[:, :s - d] = G[:, d:]
        R = G - np.maximum(Gl, Gr)
        ridge = (R >= pb["ridge_delta"]) & (G >= p["y_min"])
        yellow = (ridge & (hc >= p["yellow_h_lo"]) & (hc <= p["yellow_h_hi"])
                  & (sc >= p["yellow_s_min"]))
        white = ridge & (sc <= p["white_s_max"])
        return yellow | white

    def _band_homography(self, vx, vy, yt, yb, size):
        pb = self.pb
        W = self.W
        s = int(size)
        if (yb - vy) == 0:
            frac = 1.0
        else:
            frac = (yt - vy) / (yb - vy)
        HS = pb["half_span_frac"] * W
        src = np.float32([[vx - HS, yb], [vx + HS, yb],
                          [vx - HS * frac, yt], [vx + HS * frac, yt]])
        dst = np.float32([[0, s - 1], [s - 1, s - 1],
                          [0, 0], [s - 1, 0]])
        return cv2.getPerspectiveTransform(src, dst)

    def _vps_score(self, frames, vx, vy, yt, yb, size, hp_win):
        s = int(size)
        if len(frames) == 0:
            return -1.0
        c = np.zeros(s, dtype=np.float64)
        for f in frames:
            M = self._band_homography(vx, vy, yt, yb, size)
            m = self._ridge_bev_with(f, M, size)
            c += m.sum(axis=0)
        min_mass = (self.pb["vps_min_mass_per_frame"] * len(frames)
                    * (s / 400.0) ** 2)
        tot = float(c.sum())
        if tot < min_mass:
            return -1.0
        win = max(3, int(round(hp_win * s / 400.0)))
        if win % 2 == 0:
            win += 1
        mean = self._smooth(c, win)
        hp = np.maximum(c - mean, 0.0)
        return float((hp ** 2).sum() / (tot ** 2))

    def _vps_debug(self, frames, vx, vy, yt, yb, size, score):
        pb = self.pb
        f0 = frames[0]
        H0, W0 = f0.shape[:2]
        left = cv2.resize(f0, (960, 540))
        sx = 960.0 / W0
        sy = 540.0 / H0
        yb_s = int(round(yb * sy))
        yt_s = int(round(yt * sy))
        cv2.line(left, (0, yt_s), (959, yt_s), (0, 255, 255), 1)
        cv2.line(left, (0, yb_s), (959, yb_s), (0, 255, 255), 1)
        vpx_s = int(round(vx * sx))
        vpy_s = int(round(vy * sy))
        for i in range(9):
            xb = i * (W0 - 1) / 8.0
            cv2.line(left, (vpx_s, vpy_s),
                     (int(round(xb * sx)), yb_s), (0, 255, 0), 1)
        cv2.circle(left, (vpx_s, vpy_s), 6, (0, 0, 255), -1)

        s = int(size)
        acc = np.zeros((s, s), dtype=bool)
        for f in frames:
            M = self._band_homography(vx, vy, yt, yb, size)
            acc |= self._ridge_bev_with(f, M, size)
        bev = (acc.astype(np.uint8)) * 255
        bev = cv2.cvtColor(bev, cv2.COLOR_GRAY2BGR)
        right = cv2.resize(bev, (540, 540), interpolation=cv2.INTER_NEAREST)
        cv2.rectangle(right, (0, 540 - 26), (540, 540), (0, 0, 0), -1)
        txt = (f"VP({int(round(vx))},{int(round(vy))}) "
               f"yb={int(round(yb))} score={score:.4f}")
        cv2.putText(right, txt, (6, 540 - 8), cv2.FONT_HERSHEY_SIMPLEX,
                    0.55, (255, 255, 255), 1, cv2.LINE_AA)
        return np.hstack([left, right])

    def calibrate(self, frames):
        p = self.p
        pb = self.pb
        base = super().calibrate(frames)
        H, W = self.H, self.W
        self.hough_vp_x = float(self.vp_x)
        self.hough_vp_y = float(self.vp_y)
        self.hough_y_bot = int(self.y_bot)
        base["hough_vp_x"] = float(self.hough_vp_x)
        base["hough_vp_y"] = float(self.hough_vp_y)
        base["hough_y_bot"] = int(self.hough_y_bot)
        if not pb.get("vp_search", False):
            return base
        if pb.get("vps_mode", "closed_loop") == "closed_loop":
            return self._calibrate_closed_loop(frames, base)
        t0 = time.perf_counter()
        band_h = pb["vps_band_h_frac"] * H
        yb_list = []
        for off in pb["vps_yb_offsets"]:
            yb = float(np.clip(base["y_bot"] + float(off) * H, 0.4 * H, H - 10))
            yb_list.append((float(off), yb))
        x_lo = pb["vps_x_lo"] * W
        x_hi = pb["vps_x_hi"] * W
        x_step = pb["vps_x_step"] * W
        y_lo = pb["vps_y_lo"] * H
        y_step = pb["vps_y_step"] * H
        y_margin = pb["vps_y_margin"] * H
        coarse_frames = frames[:max(1, min(len(frames),
                                           int(pb["vps_coarse_frames"])))]
        nx = int(math.floor((x_hi - x_lo) / x_step)) + 1
        results = []
        best = None
        for off, yb in yb_list:
            yt = yb - band_h
            y_hi = yt - y_margin
            if y_hi <= y_lo:
                continue
            ny = int(math.floor((y_hi - y_lo) / y_step)) + 1
            for ix in range(nx):
                vx = x_lo + ix * x_step
                for iy in range(ny):
                    vy = y_lo + iy * y_step
                    sc = self._vps_score(coarse_frames, vx, vy, yt, yb,
                                         pb["vps_coarse_size"], pb["vps_hp_win"])
                    results.append((sc, vx, vy, off, yb))
                    if sc >= 0 and (best is None or sc > best[0]):
                        best = (sc, vx, vy, off, yb)
        results.sort(key=lambda r: -r[0])
        top5 = [[round(float(r[1]), 1), round(float(r[2]), 1),
                 round(float(r[3]), 4), round(float(r[0]), 4)]
                for r in results[:5]]
        if best is None:
            self.vps_debug_img = None
            base["vps_score"] = -1.0
            base["vps_yb_off"] = None
            base["vps_top5"] = top5
            base["vps_ms"] = round((time.perf_counter() - t0) * 1000.0, 1)
            return base
        _, bvx, bvy, boff, byb = best
        yt_b = byb - band_h
        y_hi_b = yt_b - y_margin
        fine_frames = frames[:max(1, min(len(frames),
                                         int(pb["vps_fine_frames"])))]
        fdiv = float(pb["vps_fine_div"])
        rng = int(pb["vps_fine_range"])
        fine_best = None
        for i in range(-rng, rng + 1):
            vx = bvx + i * (x_step / fdiv)
            for j in range(-rng, rng + 1):
                vy = bvy + j * (y_step / fdiv)
                if vy >= y_hi_b:
                    continue
                sc = self._vps_score(fine_frames, vx, vy, yt_b, byb,
                                     pb["vps_fine_size"], pb["vps_hp_win"])
                if sc >= 0 and (fine_best is None or sc > fine_best[0]):
                    fine_best = (sc, vx, vy)
        if fine_best is None:
            fscore, fvx, fvy = best[0], bvx, bvy
        else:
            fscore, fvx, fvy = fine_best
        self.vp_x = float(fvx)
        self.vp_y = float(fvy)
        self.y_bot = int(round(byb))
        y_top = int(self.vp_y + max(
            0.04 * H, p["roi_skip_frac"] * (self.y_bot - self.vp_y)))
        if self.y_bot - y_top < p["roi_min_h_frac"] * H:
            y_top = self.y_bot - int(p["roi_min_h_frac"] * H)
        if y_top < 0:
            y_top = 0
        self.y_top = y_top
        self.dash_y = self.y_bot + 8
        base.update({"vp_x": self.vp_x, "vp_y": self.vp_y,
                     "y_top": int(self.y_top), "y_bot": int(self.y_bot),
                     "dash_y": int(self.dash_y),
                     "vps_score": float(fscore),
                     "vps_yb_off": float(boff),
                     "vps_top5": top5,
                     "vps_ms": round((time.perf_counter() - t0) * 1000.0, 1)})
        if pb.get("vps_debug", False) and len(frames) > 0:
            self.vps_debug_img = self._vps_debug(
                fine_frames, self.vp_x, self.vp_y, yt_b, byb,
                pb["vps_fine_size"], fscore)
        else:
            self.vps_debug_img = None
        return base

    def _reset_track_state(self):
        pb = self.pb
        self.prev_base = {"left": None, "right": None}
        self.prev_hits = {"left": 0, "right": 0}
        self.prev_done = {"left": False, "right": False}
        self.bev_win = {"left": deque(maxlen=self.win_len),
                        "right": deque(maxlen=self.win_len)}
        self.d_est = None
        self.p_est = pb["pair_p_init"]
        self.prev_pair = None
        self.t = 0.0
        self.vp_upd_cnt = 0
        self.vp_acc = None
        for d in ("left", "right"):
            s = self.sides[d]
            s["xb"] = None
            s["xt"] = None
            s["last_t"] = -1e9
            s["none"] = True
            s["color"] = "white"
            s["cov"] = 0.0
            s["line"] = "none"
            s["win"] = deque(maxlen=s["win"].maxlen)
        if hasattr(self, "vp0"):
            del self.vp0
        self._last_lines = {"left": None, "right": None}
        self._last_hits = {"left": 0, "right": 0}

    def _eval_vp(self, frames, vx, vy):
        pb = self.pb
        had_frozen = hasattr(self, "vp_frozen")
        frozen0 = getattr(self, "vp_frozen", None)
        vp0 = (self.vp_x, self.vp_y)
        inset0 = bool(pb.get("inset", False))
        self._reset_track_state()
        self.vp_x = float(vx)
        self.vp_y = float(vy)
        self.vp_frozen = True
        self.M = None
        self._mat_vp = None
        pb["inset"] = False
        min_hits = int(pb["min_hits"])
        N = len(frames)
        n_both = 0
        ssum = 0.0
        for f in frames:
            self.detect(f)
            ll = self._last_lines.get("left")
            rl = self._last_lines.get("right")
            hl = self._last_hits.get("left", 0)
            hr = self._last_hits.get("right", 0)
            if (ll is not None and rl is not None
                    and hl >= min_hits and hr >= min_hits):
                n_both += 1
                ssum += abs(ll[0]) + abs(rl[0]) + abs(ll[0] - rl[0])
        both_frac = (n_both / float(N)) if N else 0.0
        slope_mean = (ssum / n_both) if n_both > 0 else 1.0
        score = both_frac - float(pb["vpcl_lambda"]) * slope_mean
        self.vp_x, self.vp_y = vp0
        if had_frozen:
            self.vp_frozen = frozen0
        elif hasattr(self, "vp_frozen"):
            del self.vp_frozen
        pb["inset"] = inset0
        self._reset_track_state()
        return score, both_frac, slope_mean

    def _vpcl_debug(self, frame, hvx, hvy, bvx, bvy, top5,
                    both_frac, slope_mean, score):
        H0, W0 = frame.shape[:2]
        img = cv2.resize(frame, (960, 540))
        sx = 960.0 / W0
        sy = 540.0 / H0
        for r in top5:
            x = int(round(float(r[0]) * sx))
            y = int(round(float(r[1]) * sy))
            if 0 <= x < 960 and 0 <= y < 540:
                cv2.circle(img, (x, y), 4, (0, 255, 255), -1)
        cv2.circle(img, (int(round(hvx * sx)), int(round(hvy * sy))),
                   7, (255, 0, 0), -1)
        cv2.circle(img, (int(round(bvx * sx)), int(round(bvy * sy))),
                   7, (0, 0, 255), -1)
        txt = (f"best VP({int(round(bvx))},{int(round(bvy))}) "
               f"both={both_frac:.2f} slope={slope_mean:.3f} "
               f"score={score:.3f}")
        cv2.rectangle(img, (0, 540 - 26), (960, 540), (0, 0, 0), -1)
        cv2.putText(img, txt, (6, 540 - 8), cv2.FONT_HERSHEY_SIMPLEX,
                    0.6, (255, 255, 255), 1, cv2.LINE_AA)
        return img

    def _calibrate_closed_loop(self, frames, base):
        p = self.p
        pb = self.pb
        H, W = self.H, self.W
        t0 = time.perf_counter()
        had_frozen = hasattr(self, "vp_frozen")
        frozen0 = getattr(self, "vp_frozen", None)
        n_fr = max(1, int(pb["vpcl_frames"]))
        frames_cl = frames[:min(len(frames), n_fr)]
        y_bot = float(base.get("y_bot", self.y_bot))
        y_hi = min(pb["vpcl_y_hi"] * H, y_bot - pb["vpcl_y_gap"] * H)
        x_lo = pb["vpcl_x_lo"] * W
        x_hi = pb["vpcl_x_hi"] * W
        x_step = pb["vpcl_x_step"] * W
        y_lo = pb["vpcl_y_lo"] * H
        y_step = pb["vpcl_y_step"] * H
        hvx = float(self.hough_vp_x)
        hvy = float(self.hough_vp_y)
        coarse = []
        hough_eval = None
        if frames_cl:
            nx = int(math.floor((x_hi - x_lo) / x_step + 1e-9)) + 1
            ny = int(math.floor((y_hi - y_lo) / y_step + 1e-9)) + 1
            for ix in range(nx):
                vx = x_lo + ix * x_step
                for iy in range(ny):
                    vy = y_lo + iy * y_step
                    if vy > y_hi:
                        continue
                    sc, bf, sm = self._eval_vp(frames_cl, vx, vy)
                    coarse.append((sc, vx, vy, bf, sm))
            if hvy <= y_hi + 1e-6:
                sc, bf, sm = self._eval_vp(frames_cl, hvx, hvy)
                hough_eval = (sc, hvx, hvy, bf, sm)
                coarse.append(hough_eval)
        if not coarse:
            base.update({"vps_mode": "closed_loop", "vpcl_best": None,
                         "vpcl_hough": None, "vpcl_top5": [],
                         "vpcl_fallback": True,
                         "vps_ms": round((time.perf_counter() - t0) * 1000.0, 1)})
            self._reset_track_state()
            if had_frozen:
                self.vp_frozen = frozen0
            elif hasattr(self, "vp_frozen"):
                del self.vp_frozen
            self.vps_debug_img = None
            return base
        coarse_sorted = sorted(coarse, key=lambda r: -r[0])
        top5 = [[round(float(r[1]), 1), round(float(r[2]), 1),
                 round(float(r[0]), 4), round(float(r[3]), 4),
                 round(float(r[4]), 4)] for r in coarse_sorted[:5]]
        bc = coarse_sorted[0]
        bvx, bvy = float(bc[1]), float(bc[2])
        fdiv = max(1, int(pb["vpcl_fine_div"]))
        fstep_x = x_step / float(fdiv)
        fstep_y = y_step / float(fdiv)
        fine = []
        for i in range(-fdiv, fdiv + 1):
            vx = bvx + i * fstep_x
            for j in range(-fdiv, fdiv + 1):
                vy = bvy + j * fstep_y
                if vy > y_hi:
                    continue
                sc, bf, sm = self._eval_vp(frames_cl, vx, vy)
                fine.append((sc, vx, vy, bf, sm))
        best = max(coarse + fine, key=lambda r: r[0])
        _, gvx, gvy, gbf, gsm = best
        best_list = [round(float(gvx), 1), round(float(gvy), 1),
                     round(float(best[0]), 4), round(float(gbf), 4),
                     round(float(gsm), 4)]
        hough_list = None if hough_eval is None else [
            round(float(hough_eval[1]), 1), round(float(hough_eval[2]), 1),
            round(float(hough_eval[0]), 4), round(float(hough_eval[3]), 4),
            round(float(hough_eval[4]), 4)]
        fallback = bool(gbf < pb["vpcl_min_both_frac"])
        if fallback:
            self.vp_x = hvx
            self.vp_y = hvy
        else:
            self.vp_x = float(gvx)
            self.vp_y = float(gvy)
            self.y_bot = int(round(y_bot))
            y_top = int(self.vp_y + max(
                0.04 * H, p["roi_skip_frac"] * (self.y_bot - self.vp_y)))
            if self.y_bot - y_top < p["roi_min_h_frac"] * H:
                y_top = self.y_bot - int(p["roi_min_h_frac"] * H)
            if y_top < 0:
                y_top = 0
            self.y_top = y_top
            self.dash_y = self.y_bot + 8
        base.update({"vps_mode": "closed_loop",
                     "vpcl_best": best_list,
                     "vpcl_hough": hough_list,
                     "vpcl_top5": top5,
                     "vpcl_fallback": fallback,
                     "vps_ms": round((time.perf_counter() - t0) * 1000.0, 1)})
        if not fallback:
            base.update({"vp_x": self.vp_x, "vp_y": self.vp_y,
                         "y_top": int(self.y_top)})
        self._reset_track_state()
        if had_frozen:
            self.vp_frozen = frozen0
        elif hasattr(self, "vp_frozen"):
            del self.vp_frozen
        if pb.get("vps_debug", False) and frames_cl:
            self.vps_debug_img = self._vpcl_debug(
                frames_cl[0], hvx, hvy, gvx, gvy, top5, gbf, gsm, best[0])
        else:
            self.vps_debug_img = None
        return base

    def _bev_to_img(self, pts):
        arr = np.asarray(pts, dtype=np.float64).reshape(-1, 1, 2)
        out = cv2.perspectiveTransform(arr, self.Minv)
        return out.reshape(-1, 2)

    def _u_ego(self):
        HS = self.pb["half_span_frac"] * self.W
        w = int(self.pb["w"])
        return (self.W * self.ego_frac - (self.vp_x - HS)) / (2.0 * HS) * (w - 1)

    @staticmethod
    def _smooth(hist, k):
        k = int(k)
        if k <= 1:
            return hist.astype(np.float64)
        ker = np.ones(k, dtype=np.float64) / k
        return np.convolve(hist.astype(np.float64), ker, mode="same")

    def _find_start(self, side, hist, u_ego):
        pb = self.pb
        w = int(pb["w"])
        if self.prev_done[side] and self.prev_base[side] is not None:
            R = pb["track_radius_frac"] * w
            lo = int(max(0, math.floor(self.prev_base[side] - R)))
            hi = int(min(w - 1, math.ceil(self.prev_base[side] + R)))
            if hi < lo:
                return None
            seg = hist[lo:hi + 1]
            if seg.size == 0:
                return None
            idx = int(np.argmax(seg))
            tracked = lo + idx if float(seg[idx]) >= pb["base_min_mass"] else None
            # 跟踪状态下也做一次全新搜索：出现明显更靠近自车的候选线时切换（防止锁死在路缘线等远处的线上）
            sm = pb.get("switch_margin_frac", None)
            if sm is None:
                return tracked
            fresh = self._fresh_start(side, hist, u_ego)
            if fresh is not None and (tracked is None or abs(fresh - u_ego) < abs(tracked - u_ego) - sm * w):
                return fresh
            return tracked
        return self._fresh_start(side, hist, u_ego)

    def _fresh_start(self, side, hist, u_ego):
        pb = self.pb
        w = int(pb["w"])
        if side == "left":
            lo = int(max(0, math.floor(u_ego - pb["base_max_off_frac"] * w)))
            hi = int(min(w - 1, math.ceil(u_ego - pb["base_min_off_frac"] * w)))
        else:
            lo = int(max(0, math.floor(u_ego + pb["base_min_off_frac"] * w)))
            hi = int(min(w - 1, math.ceil(u_ego + pb["base_max_off_frac"] * w)))
        if hi < lo:
            return None
        seg = np.asarray(hist[lo:hi + 1], dtype=np.float64)
        if seg.size == 0:
            return None
        nbh = max(0, int(pb["peak_nbhd"]))
        cands = []
        for j in range(seg.size):
            v = float(seg[j])
            if v < pb["base_min_mass"]:
                continue
            a = max(0, j - nbh)
            b = min(seg.size - 1, j + nbh)
            if v >= float(seg[a:b + 1].max()):
                cands.append(lo + j)
        if not cands:
            return None
        return min(cands, key=lambda u: abs(u - u_ego))

    def _pair_starts(self, hist, u_ego):
        pb = self.pb
        w = int(pb["w"])
        nbh = max(0, int(pb["peak_nbhd"]))
        base = float(pb["base_min_mass"])
        cands = []
        for u in range(w):
            v = float(hist[u])
            if v < base:
                continue
            a = max(0, u - nbh)
            b = min(w - 1, u + nbh)
            left_max = float(hist[a:u].max()) if u > a else -1.0
            if v >= float(hist[a:b + 1].max()) and v > left_max:
                cands.append(u)
        dbg = {"n_cands": len(cands), "cands": "", "uL": None, "uR": None,
               "d": None, "p": None, "score": None}
        if len(cands) < 2:
            dbg["cands"] = ";".join(
                f"{u}:{int(round(float(hist[u])))}" for u in cands)
            return None, None, dbg
        order = sorted(cands, key=lambda u: -float(hist[u]))
        keep = order[:int(pb["pair_max_cands"])]
        cands = sorted(keep)
        if len(cands) < 2:
            dbg["n_cands"] = len(cands)
            dbg["cands"] = ";".join(
                f"{u}:{int(round(float(hist[u])))}" for u in cands)
            return None, None, dbg
        m_max = max(float(hist[u]) for u in cands)
        dbg["n_cands"] = len(cands)
        dbg["cands"] = ";".join(
            f"{u}:{int(round(float(hist[u])))}" for u in cands)
        wmin = float(pb["pair_w_min_frac"]) * w
        wmax = float(pb["pair_w_max_frac"]) * w
        best = None
        for i in range(len(cands)):
            for j in range(i + 1, len(cands)):
                uL = float(cands[i])
                uR = float(cands[j])
                d = uR - uL
                if d < wmin or d > wmax:
                    continue
                p = (u_ego - uL) / d
                if p < pb["pair_p_lo"] or p > pb["pair_p_hi"]:
                    continue
                mL = float(hist[cands[i]])
                mR = float(hist[cands[j]])
                score = (pb["pair_wm"] * (math.sqrt(mL) + math.sqrt(mR))
                         / (2.0 * math.sqrt(m_max))) if m_max > 0 else 0.0
                if self.d_est is not None and self.d_est > 0:
                    score -= pb["pair_ww"] * abs(d - self.d_est) / self.d_est
                    denom = self.d_est
                else:
                    denom = d
                score -= pb["pair_wp"] * abs(p - self.p_est)
                if self.prev_pair is not None and denom > 0:
                    score -= pb["pair_wt"] * (
                        abs(uL - self.prev_pair[0])
                        + abs(uR - self.prev_pair[1])) / denom
                if best is None or score > best[0]:
                    best = (score, uL, uR, d, p)
        if best is None:
            return None, None, dbg
        dbg.update({"uL": best[1], "uR": best[2], "d": best[3],
                    "p": best[4], "score": best[0]})
        return best[1], best[2], dbg

    def _slide(self, start, bev_m):
        pb = self.pb
        w, h = int(pb["w"]), int(pb["h"])
        wh = h // int(pb["n_win"])
        mw = max(4, int(pb["win_half_frac"] * w))
        if wh <= 0:
            return None
        cx = float(start)
        hits = 0
        fit_v = []
        fit_u = []
        wins = []
        for k in range(int(pb["n_win"])):
            y0 = max(0, h - (k + 1) * wh)
            y1 = min(h, h - k * wh)
            c0 = int(max(0, math.floor(cx) - mw))
            c1 = int(min(w, math.floor(cx) + mw + 1))
            hit = False
            if y1 > y0 and c1 > c0:
                sub = bev_m[y0:y1, c0:c1]
                nz = int(np.count_nonzero(sub))
                if nz > 0:
                    ys, xs = np.nonzero(sub)
                    if nz >= pb["minpix"]:
                        cx = float(np.mean(xs)) + c0
                    if nz >= pb["hit_pix"]:
                        hit = True
                        fit_v.extend((ys + y0).tolist())
                        fit_u.extend((xs + c0).tolist())
            if hit:
                hits += 1
            wins.append((c0, y0, c1, y1, hit))
        line = None
        if hits >= pb["min_hits"] and len(fit_v) >= 2:
            vv = np.asarray(fit_v, dtype=np.float64)
            uu = np.asarray(fit_u, dtype=np.float64)
            if float(np.ptp(vv)) > 0:
                a, b = np.polyfit(vv, uu, 1)
                line = (float(a), float(b))
        return line, hits, wins

    def _ngap(self, occ, step):
        thr = self.pb["gap_min_frac"] * int(self.pb["h"])
        gaps = 0
        run = 0
        for o in occ:
            if not o:
                run += 1
            else:
                if run > 0 and run * step >= thr:
                    gaps += 1
                run = 0
        if run > 0 and run * step >= thr:
            gaps += 1
        return gaps

    def _classify_line(self, line, bev_m, bev_y):
        pb = self.pb
        w, h = int(pb["w"]), int(pb["h"])
        a, b = line
        step = max(1, int(pb["row_step"]))
        pw = max(2, int(pb["probe_half_frac"] * w))
        occ = []
        occ_n = 0
        yel = 0
        v0 = int(h * (1.0 - pb["cls_rows_frac"]))
        for v in range(v0, h, step):
            u = a * v + b
            c0 = int(max(0, math.floor(u - pw)))
            c1 = int(min(w, math.ceil(u + pw) + 1))
            o = False
            if c1 > c0:
                o = bool(bev_m[v, c0:c1].any())
            occ.append(o)
            if o:
                occ_n += 1
                if bev_y[v, c0:c1].any():
                    yel += 1
        n = len(occ)
        cov = occ_n / float(n) if n else 0.0
        # 最长连续占用段：实线即使远段被车遮挡也有长连续段，虚线每段只有约 2 m
        max_run = run = 0
        for o in occ:
            run = run + 1 if o else 0
            max_run = max(max_run, run)
        if cov < pb["dash_lo"]:
            cat = "none"
        elif pb.get("cls_mode", "cov") == "run":
            cat = "solid" if max_run * step >= pb.get("solid_run_frac", 0.35) * (h - v0) else "dashed"
        elif cov >= pb["solid_cov"] and self._ngap(occ, step) == 0:
            cat = "solid"
        else:
            cat = "dashed"
        color = "yellow" if (occ_n > 0 and
                             (yel / float(occ_n)) >= pb["yellow_frac"]) else "white"
        dbl = self._double_yellow(line, bev_y)
        return cat, color, dbl, cov

    def _double_yellow(self, line, bev_y):
        pb = self.pb
        w, h = int(pb["w"]), int(pb["h"])
        colhist = bev_y.sum(axis=0).astype(np.float64)
        if colhist.size == 0 or float(colhist.max()) <= 0:
            return False
        a, b = line
        u0 = a * (h - 1) + b
        rmax = pb["double_max_frac"] * w
        rmin = pb["double_min_frac"] * w
        c0 = int(max(0, math.floor(u0 - rmax)))
        c1 = int(min(w, math.ceil(u0 + rmax) + 1))
        if c1 <= c0:
            return False
        seg = colhist[c0:c1]
        j = int(np.argmax(seg))
        p1 = float(seg[j])
        x1 = c0 + j
        if p1 <= 0:
            return False
        idxs = np.arange(w, dtype=np.float64)
        dist = np.abs(idxs - x1)
        mask = (dist >= rmin) & (dist <= rmax)
        if not mask.any():
            return False
        p2 = float(colhist[mask].max())
        return p2 >= pb["double_peak_ratio"] * p1

    def _time_classify(self, side):
        win = list(self.bev_win[side])
        if not win:
            return "none"
        non_none = [x for x in win if x[0] != "none"]
        if len(non_none) < self.win_len / 2.0:
            return "none"
        n_solid = sum(1 for x in non_none if x[0] == "solid")
        n_dash = sum(1 for x in non_none if x[0] == "dashed")
        kind = "solid" if n_solid >= n_dash else "dashed"
        n_yel = sum(1 for x in non_none if x[1] == "yellow")
        base = "yellow" if n_yel > (len(non_none) - n_yel) else "white"
        if kind == "solid":
            n_dbl = sum(1 for x in non_none if x[2])
            if n_dbl > len(non_none) / 2.0:
                return "double_yellow"
            return base + "_solid"
        return base + "_dashed"

    @staticmethod
    def _line_inter(p1, p2, p3, p4):
        l1 = np.cross([p1[0], p1[1], 1.0], [p2[0], p2[1], 1.0])
        l2 = np.cross([p3[0], p3[1], 1.0], [p4[0], p4[1], 1.0])
        x = np.cross(l1, l2)
        if abs(x[2]) < 1e-9:
            return None
        return float(x[0] / x[2]), float(x[1] / x[2])

    def _debug_img(self, bev_m, bev_y, bev_gray, lines, kinds, wins_all, u_ego,
                   pair_dbg=None):
        pb = self.pb
        w, h = int(pb["w"]), int(pb["h"])
        if bev_gray is not None:
            base = (bev_gray.astype(np.float32) * 0.5).astype(np.uint8)
            img = cv2.cvtColor(base, cv2.COLOR_GRAY2BGR)
        else:
            img = np.full((h, w, 3), 64, dtype=np.uint8)
        img[bev_m] = (255, 255, 255)
        img[bev_y] = (0, 255, 255)
        for d in ("left", "right"):
            for (x0, y0, x1, y1, hit) in wins_all[d]:
                col = (0, 255, 0) if hit else (128, 128, 128)
                cv2.rectangle(img, (int(x0), int(y0)),
                              (int(max(x0, x1 - 1)), int(max(y0, y1 - 1))),
                              col, 1)
        for d in ("left", "right"):
            line = lines[d]
            if line is None:
                continue
            a, b = line
            col = (0, 0, 255) if kinds[d] == "solid" else (0, 255, 0)
            cv2.line(img, (int(b), 0), (int(a * (h - 1) + b), h - 1), col, 2)
        cv2.line(img, (int(u_ego), 0), (int(u_ego), h - 1), (255, 255, 0), 1)
        if pair_dbg is not None:
            for s in str(pair_dbg.get("cands") or "").split(";"):
                if not s:
                    continue
                try:
                    u = int(float(s.split(":")[0]))
                except ValueError:
                    continue
                cv2.line(img, (u, h - 1), (u, h - 16), (255, 0, 255), 1)
            for key in ("uL", "uR"):
                u = pair_dbg.get(key)
                if u is None:
                    continue
                cv2.line(img, (int(u), h - 1), (int(u), h - 26),
                         (255, 0, 255), 3)
        return img

    def detect(self, frame):
        pb = self.pb
        W, H = self.W, self.H
        w, h = int(pb["w"]), int(pb["h"])

        if (self.M is None or self._mat_vp is None
                or abs(self.vp_x - self._mat_vp[0]) > 0.5
                or abs(self.vp_y - self._mat_vp[1]) > 0.5):
            self._build_homography()

        if pb["use_ridge"]:
            bev_m, bev_y, bev_gray = self._marking_bev(frame)
        else:
            markings, yellow = self._marking(frame, self.bev_yt, self.y_bot + 1)
            bev_m = cv2.warpPerspective(markings, self.M, (w, h),
                                        flags=cv2.INTER_LINEAR) > 0
            bev_y = cv2.warpPerspective(yellow, self.M, (w, h),
                                        flags=cv2.INTER_LINEAR) > 0
            bev_gray = None

        h0 = int(h * (1.0 - pb["hist_rows_frac"]))
        hist = bev_m[h0:, :].sum(axis=0)
        hist = self._smooth(hist, pb["hist_smooth"])
        u_ego = self._u_ego()

        pair_mode = bool(pb.get("pair_mode", False))
        pair_dbg = None
        pair_used = False
        if pair_mode:
            uL, uR, pdbg = self._pair_starts(hist, u_ego)
            if uL is not None and uR is not None:
                starts = {"left": uL, "right": uR}
                pdbg["fallback"] = False
                pair_used = True
            else:
                starts = {d: self._find_start(d, hist, u_ego)
                          for d in ("left", "right")}
                pdbg["fallback"] = True
            pair_dbg = pdbg
        else:
            starts = {d: self._find_start(d, hist, u_ego)
                      for d in ("left", "right")}
        ls, rs = starts["left"], starts["right"]
        if (not pair_used and ls is not None and rs is not None
                and abs(ls - rs) < pb["same_line_frac"] * w):
            dl = (abs(ls - self.prev_base["left"])
                  if self.prev_base["left"] is not None else 1e18)
            dr = (abs(rs - self.prev_base["right"])
                  if self.prev_base["right"] is not None else 1e18)
            if dl <= dr:
                starts["right"] = None
            else:
                starts["left"] = None

        res = {"left_line": "none", "right_line": "none",
               "left_cov": 0.0, "right_cov": 0.0,
               "left_xb": None, "left_xt": None,
               "right_xb": None, "right_xt": None,
               "bev_img": None, "pair_dbg": None}
        lines = {"left": None, "right": None}
        hits = {"left": 0, "right": 0}
        kinds = {"left": "none", "right": "none"}
        wins_all = {"left": [], "right": []}

        for d in ("left", "right"):
            if starts[d] is None:
                continue
            out = self._slide(starts[d], bev_m)
            if out is None:
                continue
            line, hh, wws = out
            lines[d] = line
            hits[d] = hh
            wins_all[d] = wws

        for d in ("left", "right"):
            line = lines[d]
            if line is None:
                self.bev_win[d].append(("none", "white", False))
                self.prev_done[d] = False
                self.prev_hits[d] = 0
                res[d + "_line"] = self._time_classify(d)
                res[d + "_cov"] = 0.0
                continue
            cat, color, dbl, cov = self._classify_line(line, bev_m, bev_y)
            kinds[d] = cat
            self.bev_win[d].append((cat, color, dbl))
            self.prev_done[d] = hits[d] >= pb["min_hits"]
            self.prev_hits[d] = hits[d]
            res[d + "_line"] = self._time_classify(d)
            res[d + "_cov"] = float(cov)
            a, b = line
            pts = np.array([[a * (h - 1) + b, h - 1], [b, 0]], dtype=np.float64)
            ip = self._bev_to_img(pts)
            res[d + "_xb"] = float(ip[0, 0])
            res[d + "_xt"] = float(ip[1, 0])

        for d in ("left", "right"):
            if starts[d] is not None:
                self.prev_base[d] = float(starts[d])

        if (pair_used and hits["left"] >= pb["min_hits"]
                and hits["right"] >= pb["min_hits"]):
            d_pair = float(starts["right"]) - float(starts["left"])
            if d_pair > 0:
                ema = pb["pair_ema"]
                self.d_est = (d_pair if self.d_est is None
                              else (1.0 - ema) * self.d_est + ema * d_pair)
                p_pair = (u_ego - float(starts["left"])) / d_pair
                self.p_est = (1.0 - ema) * self.p_est + ema * p_pair
                self.prev_pair = (float(starts["left"]),
                                  float(starts["right"]))

        if pair_dbg is not None:
            pair_dbg["d_est"] = self.d_est
            pair_dbg["p_est"] = self.p_est
            res["pair_dbg"] = pair_dbg

        if (pb["vp_refine"] and not getattr(self, "vp_frozen", False)
                and lines["left"] is not None and lines["right"] is not None
                and hits["left"] >= pb["vp_refine_min_hits"]
                and hits["right"] >= pb["vp_refine_min_hits"]):
            pa, pb_ = lines["left"]
            qa, qb = lines["right"]
            p1 = np.array([pa * (h - 1) + pb_, h - 1], dtype=np.float64)
            p2 = np.array([pb_, 0], dtype=np.float64)
            p3 = np.array([qa * (h - 1) + qb, h - 1], dtype=np.float64)
            p4 = np.array([qb, 0], dtype=np.float64)
            ip = self._bev_to_img(np.vstack([p1, p2, p3, p4]))
            X = self._line_inter(ip[0], ip[1], ip[2], ip[3])
            if X is not None:
                ix, iy = X
                if 0 <= ix < W and 0 <= iy < H:
                    sx = float(np.clip(pb["vp_alpha"] * (ix - self.vp_x),
                                       -pb["vp_max_step"], pb["vp_max_step"]))
                    sy = float(np.clip(pb["vp_alpha"] * (iy - self.vp_y),
                                       -pb["vp_max_step"], pb["vp_max_step"]))
                    self.vp_x += sx
                    self.vp_y += sy
                    # 自校正只允许在初始标定值附近浮动，防止选错线对时 VP 越修越偏
                    if not hasattr(self, "vp0"):
                        self.vp0 = (self.vp_x - sx, self.vp_y - sy)
                    dx = pb.get("vp_max_dev_x_frac", 9.0) * W
                    dy = pb.get("vp_max_dev_y_frac", 9.0) * H
                    self.vp_x = float(np.clip(self.vp_x, self.vp0[0] - dx, self.vp0[0] + dx))
                    self.vp_y = float(np.clip(self.vp_y, self.vp0[1] - dy, self.vp0[1] + dy))

        self._last_lines = dict(lines)
        self._last_hits = dict(hits)
        if pb["inset"]:
            res["bev_img"] = self._debug_img(bev_m, bev_y, bev_gray, lines,
                                             kinds, wins_all, u_ego,
                                             pair_dbg)
        return res
