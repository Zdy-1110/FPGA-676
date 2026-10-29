import cv2
import numpy as np


COLOR_NAMES = ("red", "yellow", "green")


def _color_mask(h, s, v, spec):
    h_lo = spec["h_lo"]
    h_hi = spec["h_hi"]
    if h_lo > h_hi:
        base = (h >= h_lo) | (h <= h_hi)
    else:
        base = (h >= h_lo) & (h <= h_hi)
    return base & (s >= spec["s_min"]) & (v >= spec["v_min"])


class TLDetector:
    def __init__(self, params_tl):
        self.p = params_tl
        self.sq3 = np.ones((3, 3), np.uint8)
        ck = int(params_tl.get("close_kernel", 3))
        self.close_kernel = np.ones((ck, ck), np.uint8)

    def _shape(self, b):
        h, w = b.shape
        if min(w, h) < self.p["shape_min_size"]:
            return "unknown"
        r = self.p["shape_arrow_ratio"]
        row_w = b.sum(axis=1).astype(np.float64)
        col_h = b.sum(axis=0).astype(np.float64)
        n3r = max(1, h // 3)
        n3c = max(1, w // 3)
        top_w = float(row_w[:n3r].mean())
        bot_w = float(row_w[h - n3r:].mean())
        left_h = float(col_h[:n3c].mean())
        right_h = float(col_h[w - n3c:].mean())
        fill = float(b.mean())
        # 箭头只在接近方形的包围盒上成立（行人灯小人偏瘦高，易被误判为箭头）
        # 实心圆（含灯罩遮挡）填充率约 0.7，箭头约 0.4–0.55：先按填充率判圆灯
        if self.p.get("round_first", False) and fill >= self.p["shape_round_fill"]:
            return "round"
        if not (self.p.get("arrow_aspect_min", 0.0) <= w / float(h) <= self.p.get("arrow_aspect_max", 99.0)):
            return "round" if fill >= self.p["shape_round_fill"] else "unknown"
        if right_h > 0 and left_h >= r * right_h:
            return "left"
        if left_h > 0 and right_h >= r * left_h:
            return "right"
        if bot_w > 0 and top_w >= r * bot_w:
            return "straight"
        if fill >= self.p["shape_round_fill"]:
            return "round"
        return "unknown"

    def detect(self, frame):
        H, W = frame.shape[:2]
        roi_h = int(H * self.p["roi_y_max_frac"])
        if roi_h < 1:
            roi_h = H
        roi = frame[0:roi_h]
        hsv = cv2.cvtColor(roi, cv2.COLOR_BGR2HSV_FULL)
        hc = hsv[:, :, 0]
        sc = hsv[:, :, 1]
        vc = hsv[:, :, 2]

        bloom_v = self.p["bloom_v"]
        lights = []
        for cname in COLOR_NAMES:
            mask = _color_mask(hc, sc, vc, self.p[cname]).astype(np.uint8)
            bmask = (mask > 0)
            bloom = (vc >= bloom_v) & (cv2.dilate(mask, self.sq3) > 0)
            mask = (bmask | bloom).astype(np.uint8)
            mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, self.close_kernel)

            n, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
            for i in range(1, n):
                x, y, w, h, area = (int(stats[i, 0]), int(stats[i, 1]),
                                    int(stats[i, 2]), int(stats[i, 3]),
                                    int(stats[i, 4]))
                if w < self.p["min_w"] or w > self.p["max_w"]:
                    continue
                if h < self.p["min_h"] or h > self.p["max_h"]:
                    continue
                if area < self.p["min_area"]:
                    continue
                aspect = w / float(h)
                if aspect < self.p["aspect_min"] or aspect > self.p["aspect_max"]:
                    continue
                fill = area / float(w * h)
                if fill < self.p["min_fill"]:
                    continue

                comp = (labels[y:y + h, x:x + w] == i)
                # 灯面亮度：点亮的灯明显比红圈标志、尾灯等亮
                if float(np.median(vc[y:y + h, x:x + w][comp])) < self.p.get("lamp_v_min", 0):
                    continue
                # 中心填充：限速牌红圈等环形目标中心为空
                ch0, cw0 = h // 3, w // 3
                if comp[ch0:h - ch0, cw0:w - cw0].mean() < self.p.get("center_fill_min", 0.0):
                    continue
                if self.p.get("housing_mode", "ring") == "side":
                    # 横排灯箱：左右紧邻的灯头位至少一侧偏暗（未点亮的灯头或灯箱）
                    lb = vc[y:y + h, max(0, x - w):x]
                    rb = vc[y:y + h, x + w:min(W, x + 2 * w)]
                    side_v = min(float(np.median(lb)) if lb.size else 255.0,
                                 float(np.median(rb)) if rb.size else 255.0)
                    if side_v > self.p.get("housing_side_v", 110):
                        continue
                    b = comp
                    lights.append({"x1": x, "y1": y, "x2": x + w, "y2": y + h, "color": cname,
                                   "shape": self._shape(b), "area": area, "dark_frac": side_v})
                    continue
                ex = int(self.p["housing_expand_x"] * max(w, h))
                ey = int(self.p["housing_expand_y"] * h)
                x1e = max(0, x - ex)
                y1e = max(0, y - ey)
                x2e = min(W, x + w + ex)
                y2e = min(roi_h, y + h + ey)
                dark_frac = 0.0
                if x2e > x1e and y2e > y1e:
                    sub = vc[y1e:y2e, x1e:x2e]
                    ring = np.ones(sub.shape, dtype=bool)
                    rx1 = x - x1e
                    ry1 = y - y1e
                    ring[ry1:ry1 + h, rx1:rx1 + w] = False
                    tot = int(ring.sum())
                    if tot > 0:
                        dark_frac = float((sub[ring] < self.p["housing_dark_v"]).sum()) / tot
                if dark_frac < self.p["housing_dark_frac"]:
                    continue

                b = (labels[y:y + h, x:x + w] == i)
                shape = self._shape(b)

                lights.append({
                    "x1": x, "y1": y, "x2": x + w, "y2": y + h,
                    "color": cname, "shape": shape, "area": area,
                    "dark_frac": dark_frac,
                })

        if len(lights) >= 1:
            cys = [0.5 * (l["y1"] + l["y2"]) for l in lights]
            hs = [l["y2"] - l["y1"] for l in lights]
            y0 = min(cys)
            hm = float(np.median(hs))
            lim = y0 + self.p["row_drop_factor"] * hm
            lights = [l for l, cy in zip(lights, cys) if cy <= lim]
        return lights


def associate(lights):
    prio = {"red": 3, "yellow": 2, "green": 1}
    result = []
    for d in ("left", "straight", "right"):
        cand = [l for l in lights if l["shape"] == d]
        if not cand and d in ("left", "straight"):
            cand = [l for l in lights if l["shape"] in ("round", "unknown")]
        if not cand:
            result.append("none")
            continue
        sums = {}
        for l in cand:
            sums[l["color"]] = sums.get(l["color"], 0) + l["area"]
        best = None
        best_key = None
        for col, tot in sums.items():
            key = (tot, prio.get(col, 0))
            if best_key is None or key > best_key:
                best_key = key
                best = col
        result.append(best)
    return result[0], result[1], result[2]


class TLFilter:
    def __init__(self, params_tl, fps_eff):
        self.p = params_tl
        self.dt = 1.0 / fps_eff
        self.t = 0.0
        self.st = {}
        for d in ("left", "straight", "right"):
            self.st[d] = {"value": "none", "cand": None, "cnt": 0,
                          "last_non_none_t": -1e9}

    def update(self, raw3, ego_stopped):
        self.t += self.dt
        out = []
        k = self.p["filter_k"]
        hold = self.p["hold_moving_s"]
        for d, raw in zip(("left", "straight", "right"), raw3):
            s = self.st[d]
            if raw != "none":
                s["last_non_none_t"] = self.t
                if raw == s["value"]:
                    s["cnt"] = 0
                    s["cand"] = None
                else:
                    if raw == s["cand"]:
                        s["cnt"] += 1
                    else:
                        s["cand"] = raw
                        s["cnt"] = 1
                    if s["cnt"] >= k:
                        s["value"] = raw
                        s["cnt"] = 0
                        s["cand"] = None
            else:
                if ego_stopped:
                    pass
                elif s["value"] != "none" and (self.t - s["last_non_none_t"]) > hold:
                    s["value"] = "none"
                    s["cnt"] = 0
                    s["cand"] = None
            out.append(s["value"])
        return out[0], out[1], out[2]
