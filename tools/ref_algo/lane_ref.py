import math
from collections import deque

import cv2
import numpy as np


class LaneDetector:
    def __init__(self, params_lane, fps_eff, W=1920, H=1080):
        self.p = params_lane
        self.fps_eff = fps_eff
        self.W = W
        self.H = H
        self.dt = 1.0 / fps_eff
        self.t = 0.0
        self.dash_y = H - 1
        self.y_top = int((H - 1) - int(params_lane["roi_height_frac"] * H))
        self.y_bot = H - 1
        self.vp_x = W / 2.0
        self.vp_y = H / 2.0
        self.vp_ok = False
        self.vp_votes = 0.0
        self.vp_acc = None
        self.vp_gx0 = 0.0
        self.vp_gy0 = 0.0
        self.vp_nx = 1
        self.vp_ny = 1
        self.vp_cell = int(params_lane["vp_cell"])
        self.vp_upd_every = max(
            1, int(round(params_lane["vp_update_s"] * fps_eff)))
        self.vp_upd_cnt = 0
        wp = max(1, int(round(params_lane["win_s"] * fps_eff)))
        self.sides = {}
        for d in ("left", "right"):
            self.sides[d] = {
                "xb": None, "xt": None, "last_t": -1e9, "none": True,
                "color": "white", "cov": 0.0, "line": "none",
                "win": deque(maxlen=wp),
            }

    def _init_grid(self):
        p = self.p
        cell = self.vp_cell
        self.vp_gx0 = p["vp_x0_frac"] * self.W
        self.vp_gy0 = p["vp_y0_frac"] * self.H
        gx1 = p["vp_x1_frac"] * self.W
        gy1 = p["vp_y1_frac"] * self.H
        self.vp_nx = max(1, int(math.ceil((gx1 - self.vp_gx0) / cell)))
        self.vp_ny = max(1, int(math.ceil((gy1 - self.vp_gy0) / cell)))

    def _extract(self, frame, y0, y1):
        p = self.p
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
        mu8 = (markings.astype(np.uint8)) * 255
        lines = cv2.HoughLinesP(mu8, 1, math.pi / 180.0,
                                int(p["hough_thresh"]),
                                minLineLength=int(p["hough_min_len"]),
                                maxLineGap=int(p["hough_max_gap"]))
        segs = []
        if lines is not None:
            for ln in np.asarray(lines).reshape(-1, 4):
                x1 = int(ln[0])
                y1r = int(ln[1])
                x2 = int(ln[2])
                y2r = int(ln[3])
                dy = y2r - y1r
                dx = x2 - x1
                if dy == 0:
                    continue
                ang = math.degrees(math.atan2(abs(dy), abs(dx)))
                if ang < p["angle_min_deg"] or ang > p["angle_max_deg"]:
                    continue
                segs.append((x1, y1r + y0, x2, y2r + y0))
        return segs, markings, yellow

    def _vote(self, segs, acc):
        p = self.p
        cell = self.vp_cell
        left = []
        right = []
        for x1, Y1, x2, Y2 in segs:
            dy = Y2 - Y1
            if dy == 0:
                continue
            sl = (x2 - x1) / float(dy)
            L = math.hypot(x2 - x1, Y2 - Y1)
            if sl < 0:
                left.append((x1, Y1, sl, L))
            elif sl > 0:
                right.append((x1, Y1, sl, L))
        left.sort(key=lambda t: t[3], reverse=True)
        right.sort(key=lambda t: t[3], reverse=True)
        ms = int(p["vp_max_segs"])
        left = left[:ms]
        right = right[:ms]
        for x1, Y1, sl, ll in left:
            for x2, Y2, sr, lr in right:
                den = sl - sr
                if abs(den) < 1e-9:
                    continue
                yv = (x2 - x1 + sl * Y1 - sr * Y2) / den
                xv = x1 + sl * (yv - Y1)
                ix = int(math.floor((xv - self.vp_gx0) / cell))
                iy = int(math.floor((yv - self.vp_gy0) / cell))
                if 0 <= ix < self.vp_nx and 0 <= iy < self.vp_ny:
                    acc[iy, ix] += ll * lr

    def _argmax_vp(self, acc):
        sm = cv2.blur(acc.astype(np.float32), (3, 3))
        iy, ix = np.unravel_index(int(np.argmax(sm)), sm.shape)
        cell = self.vp_cell
        self.vp_x = self.vp_gx0 + (ix + 0.5) * cell
        self.vp_y = self.vp_gy0 + (iy + 0.5) * cell

    def calibrate(self, frames):
        p = self.p
        n = max(1, min(len(frames), p["calib_frames"]))
        use = frames[:n]
        if use:
            self.H, self.W = use[0].shape[:2]
        H, W = self.H, self.W
        self._init_grid()
        acc = np.zeros((self.vp_ny, self.vp_nx), dtype=np.float64)
        segs_all = []
        y0 = int(p["calib_y0_frac"] * H)
        y1 = int(p["calib_y1_frac"] * H)
        if y1 <= y0:
            y1 = min(H, y0 + 1)
        for f in use:
            segs, _, _ = self._extract(f, y0, y1)
            segs_all.extend(segs)
            self._vote(segs, acc)
        votes = float(acc.sum())
        self.vp_votes = votes
        self.vp_acc = acc
        if votes >= p["vp_min_votes"]:
            self._argmax_vp(acc)
            self.vp_ok = True
        else:
            self.vp_x = W / 2.0
            self.vp_y = p["vp_fallback_y_frac"] * H
            self.vp_ok = False
        vp_y = self.vp_y
        ys = []
        for x1, Y1, x2, Y2 in segs_all:
            dy = Y2 - Y1
            if dy == 0:
                continue
            sl = (x2 - x1) / float(dy)
            xat = x1 + sl * (vp_y - Y1)
            if abs(xat - self.vp_x) <= p["vp_consist_px"]:
                ys.append(max(Y1, Y2))
        if ys:
            y_bot = int(np.percentile(
                np.asarray(ys, dtype=np.float64), p["ybot_pct"])) - 5
        else:
            y_bot = int(0.92 * H)
        lo = int(vp_y + p["roi_min_h_frac"] * H)
        hi = H - 10
        if y_bot < lo:
            y_bot = lo
        if y_bot > hi:
            y_bot = hi
        self.y_bot = y_bot
        y_top = int(vp_y + max(0.04 * H, p["roi_skip_frac"] * (y_bot - vp_y)))
        if y_bot - y_top < p["roi_min_h_frac"] * H:
            y_top = y_bot - int(p["roi_min_h_frac"] * H)
        if y_top < 0:
            y_top = 0
        self.y_top = y_top
        self.dash_y = y_bot + 8
        return {"vp_x": float(self.vp_x), "vp_y": float(self.vp_y),
                "vp_ok": bool(self.vp_ok), "votes": float(votes),
                "y_top": int(self.y_top), "y_bot": int(self.y_bot),
                "dash_y": int(self.dash_y)}

    @staticmethod
    def _runs(bools):
        runs = []
        start = None
        for idx, b in enumerate(bools):
            if b and start is None:
                start = idx
            elif not b and start is not None:
                runs.append((start, idx - 1))
                start = None
        if start is not None:
            runs.append((start, len(bools) - 1))
        return runs

    def _probe(self, markings, yellow, xb, xt):
        p = self.p
        W = self.W
        y_top, y_bot = self.y_top, self.y_bot
        span = float(y_bot - y_top) if y_bot > y_top else 1.0
        rows = list(range(y_top, y_bot + 1, p["sample_step"]))
        if not rows:
            rows = [y_top]
        hits = 0
        yel_rows = 0
        white_rows = 0
        dbl_rows = 0
        for y in rows:
            r = y - y_top
            if r < 0 or r >= markings.shape[0]:
                continue
            x = xb + (y_bot - y) / span * (xt - xb)
            pw = int(p["probe_halfwidth"] * (0.5 + (y - y_top) / span))
            if pw < 2:
                pw = 2
            c0 = int(max(0, x - pw))
            c1 = int(min(W, x + pw + 1))
            if c1 <= c0:
                continue
            seg = markings[r, c0:c1]
            if not seg.any():
                continue
            hits += 1
            ny = int(yellow[r, c0:c1].sum())
            nw = int(seg.sum()) - ny
            if ny > nw:
                yel_rows += 1
            else:
                white_rows += 1
            w0 = int(max(0, x - 3 * pw))
            w1 = int(min(W, x + 3 * pw + 1))
            runs = self._runs(yellow[r, w0:w1].tolist())
            if len(runs) >= 2:
                for a, b in zip(runs[:-1], runs[1:]):
                    gap = b[0] - a[1]
                    if p["double_gap_min"] <= gap <= p["double_gap_max"]:
                        dbl_rows += 1
                        break
        cov = hits / float(len(rows))
        color = "yellow" if yel_rows > white_rows else "white"
        dbl = hits > 0 and (dbl_rows / float(hits)) >= p["double_frac"]
        return cov, color, dbl

    def _classify(self, s):
        p = self.p
        win = list(s["win"])
        if s["none"] or not win:
            return "none"
        covs = [w[0] for w in win]
        mc = float(np.mean(covs))
        if mc < p["none_mean"]:
            return "none"
        n = len(win)
        nd = sum(1 for w in win if w[2])
        if nd > n / 2.0:
            return "double_yellow"
        ny = sum(1 for w in win if w[1] == "yellow")
        base = "yellow" if ny > (n - ny) else "white"
        if mc >= p["solid_mean"] and min(covs) >= p["solid_min"]:
            return base + "_solid"
        return base + "_dashed"

    def detect(self, frame):
        p = self.p
        W, H = self.W, self.H
        y_top, y_bot = self.y_top, self.y_bot
        now = self.t
        self.t += self.dt
        vp_x, vp_y = self.vp_x, self.vp_y
        segs, markings, yellow = self._extract(frame, y_top, y_bot + 1)

        # 左右划分：center=按画面底部自车位置（镜头偏航时 VP 的 x 不代表自车位置），vp=按消失点
        cx = W * p.get("ego_x_frac", 0.5) if p.get("split_mode", "vp") == "center" else vp_x
        tol = p["vp_tol_frac"] * W
        cand = {"left": [], "right": []}
        for x1, Y1, x2, Y2 in segs:
            dy = Y2 - Y1
            if dy == 0:
                continue
            slope = (x2 - x1) / float(dy)
            x_vp = x1 + slope * (vp_y - Y1)
            if abs(x_vp - vp_x) > tol:
                continue
            xb = x1 + (y_bot - Y1) * slope
            xt = x1 + (y_top - Y1) * slope
            L = math.hypot(x2 - x1, Y2 - Y1)
            if xb < cx and xt > xb:
                cand["left"].append((xb, xt, L))
            elif xb > cx and xt < xb:
                cand["right"].append((xb, xt, L))

        if self.vp_acc is not None and not getattr(self, "vp_frozen", False):
            self.vp_acc *= p["vp_decay"]
            self._vote(segs, self.vp_acc)
            self.vp_upd_cnt += 1
            if self.vp_upd_cnt >= self.vp_upd_every:
                self.vp_upd_cnt = 0
                if self.vp_acc.sum() > 0:
                    self._argmax_vp(self.vp_acc)

        chosen = {}
        for d in ("left", "right"):
            segs = cand[d]
            if not segs:
                chosen[d] = None
                continue
            buckets = {}
            for xb, xt, L in segs:
                b = int(math.floor(xb / 40.0))
                buckets.setdefault(b, 0.0)
                buckets[b] += L
            valid = [b for b, tot in buckets.items() if tot >= p["min_support_len"]]
            if not valid:
                chosen[d] = None
                continue
            bk = max(valid) if d == "left" else min(valid)
            sel = [(xb, xt, L) for xb, xt, L in segs
                   if int(math.floor(xb / 40.0)) == bk]
            tw = sum(L for _, _, L in sel)
            if tw <= 0:
                chosen[d] = None
                continue
            xb = sum(xb * L for xb, _, L in sel) / tw
            xt = sum(xt * L for _, xt, L in sel) / tw
            chosen[d] = (xb, xt)

        res = {"left_line": "none", "right_line": "none",
               "left_cov": 0.0, "right_cov": 0.0,
               "left_xb": None, "left_xt": None,
               "right_xb": None, "right_xt": None}
        for d in ("left", "right"):
            s = self.sides[d]
            c = chosen[d]
            if c is not None:
                if s["xb"] is None or s["none"]:
                    s["xb"], s["xt"] = c
                else:
                    a = p["ema"]
                    s["xb"] = a * c[0] + (1 - a) * s["xb"]
                    s["xt"] = a * c[1] + (1 - a) * s["xt"]
                s["last_t"] = now
                s["none"] = False
            else:
                if s["xb"] is not None and (now - s["last_t"]) <= p["lost_hold_s"]:
                    s["none"] = False
                else:
                    s["none"] = True

            if s["none"] or s["xb"] is None:
                s["cov"] = 0.0
                s["win"].append((0.0, s["color"], False))
            else:
                cov, col, dbl = self._probe(markings, yellow, s["xb"], s["xt"])
                s["cov"] = cov
                s["color"] = col
                s["win"].append((cov, col, dbl))
            s["line"] = self._classify(s)

            res[d + "_line"] = s["line"]
            res[d + "_cov"] = s["cov"]
            if not s["none"] and s["xb"] is not None:
                res[d + "_xb"] = float(s["xb"])
                res[d + "_xt"] = float(s["xt"])
        return res
