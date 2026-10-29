import cv2
import numpy as np


class EgoMotion:
    def __init__(self, params_motion, roi_rows=(0, 0)):
        self.p = params_motion
        self.y_top, self.y_bot = roi_rows
        self.h = None
        self.w = None
        self.prev = None
        self.state = None

    def _prep(self, frame):
        ds = max(1, int(self.p["downscale"]))
        y_lo = int(self.y_top - 0.15 * frame.shape[0])
        if y_lo < 0:
            y_lo = 0
        y_hi = int(self.y_bot) + 1
        if y_hi > frame.shape[0]:
            y_hi = frame.shape[0]
        crop = frame[y_lo:y_hi]
        gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
        h = gray.shape[0] // ds
        w = gray.shape[1] // ds
        if h < 1 or w < 1:
            h = max(1, h)
            w = max(1, w)
        small = cv2.resize(gray, (w, h), interpolation=cv2.INTER_AREA)
        small = cv2.GaussianBlur(small, (3, 3), 0)
        return small.astype(np.float32)

    def update(self, frame):
        cur = self._prep(frame)
        if self.prev is None or self.prev.shape != cur.shape:
            self.prev = cur
            self.state = "moving"
            return "moving", 0.0
        shift, _ = cv2.phaseCorrelate(self.prev, cur)
        m = np.float32([[1, 0, shift[0]], [0, 1, shift[1]]])
        aligned = cv2.warpAffine(self.prev, m, (cur.shape[1], cur.shape[0]))
        score = float(np.mean(np.abs(aligned - cur)))
        self.prev = cur
        # 最近 smooth_n 帧取中值，压掉手持晃动造成的单帧尖峰
        self.hist = (getattr(self, "hist", []) + [score])[-int(self.p.get("smooth_n", 1)):]
        score = float(np.median(self.hist))
        if score >= self.p["move_thr"]:
            self.state = "moving"
        elif score <= self.p["stop_thr"]:
            self.state = "stopped"
        return self.state, score
