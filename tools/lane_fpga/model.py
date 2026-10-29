# -*- coding: utf-8 -*-
"""FPGA 定点流式车道线检测黄金模型。

严格按「逐行流式、无行缓冲」的硬件算法建模：
- 窗口 0 分辨率：960x540，RGB565 量化存储。
- 行处理 ROI：y in [y_top, y_bot]，逐行光栅扫描。
- 逐行脊线检测、Run 提取与宽度过滤。
- 左右侧车道线候选点动态跟踪与双线检测。
- 帧末最小二乘拟合（纯定点累加与除法求解）、RMS 校验与 EMA 跟踪。
- 32 帧滑动多数表决虚/实线分类。
- 自车车道偏离告警与变道指令判决。
"""

import json
import math
import os
import sys
from collections import deque

import numpy as np

# 自动挂载环境中的依赖
try:
    import cv2
except ImportError:
    site_pkg = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..", ".venv_yolo", "Lib", "site-packages")
    )
    if os.path.exists(site_pkg):
        sys.path.insert(0, site_pkg)
    import cv2


DEFAULT_PARAMS_PATH = os.path.join(os.path.dirname(__file__), "params.json")


def load_params(path=None):
    if path is None:
        path = DEFAULT_PARAMS_PATH
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def div_round(num, den):
    """硬件整数带符号四舍五入除法。"""
    if den == 0:
        return 0
    if den < 0:
        num, den = -num, -den
    if num >= 0:
        return (num + den // 2) // den
    else:
        return (num - den // 2) // den


class LaneSideState:
    """单侧车道线状态追踪器。"""

    def __init__(self, side, p):
        self.side = side  # "left" or "right"
        self.p = p
        self.reset()

    def reset(self):
        self.history_types = deque(maxlen=self.p.get("vote_window", 32))
        self.reseed_prior()

    def reseed_prior(self):
        """重新装入标称先验。若 params 中无先验，则置为无效冷启动。"""
        init_a = self.p.get("init_a_left" if self.side == "left" else "init_a_right")
        init_b = self.p.get("init_b_left" if self.side == "left" else "init_b_right")
        if init_a is not None and init_b is not None:
            self.valid = True
            self.a_smooth_q16 = int(round(init_a * 65536))
            self.b_smooth_q4 = int(round(init_b * 16))
            self.a_q16 = self.a_smooth_q16
            self.b_q4 = self.b_smooth_q4
            self.invalid_count = 0
        else:
            self.valid = False
            self.a_q16 = None
            self.b_q4 = None
            self.a_smooth_q16 = None
            self.b_smooth_q4 = None
            self.invalid_count = self.p.get("k_lost_frames", 8)

    def update_frame(self, fit_res, frame_type):
        """帧末更新状态与 EMA 平滑。"""
        q_a = self.p.get("q_a", 16)
        q_b = self.p.get("q_b", 4)
        alpha_shift = self.p.get("ema_alpha_shift", 2)  # α = 1/4

        if fit_res["valid"]:
            self.invalid_count = 0
            cur_a = fit_res["a_q"]
            cur_b = fit_res["b_q"]
            if self.a_smooth_q16 is None or not self.valid:
                self.a_smooth_q16 = cur_a
                self.b_smooth_q4 = cur_b
            else:
                # 定点 EMA: smooth = prev + ((cur - prev) >> alpha_shift)
                diff_a = cur_a - self.a_smooth_q16
                diff_b = cur_b - self.b_smooth_q4
                self.a_smooth_q16 += (diff_a >> alpha_shift)
                self.b_smooth_q4 += (diff_b >> alpha_shift)
            self.valid = True
            self.a_q16 = self.a_smooth_q16
            self.b_q4 = self.b_smooth_q4
        else:
            self.invalid_count += 1
            if self.invalid_count >= self.p.get("k_lost_frames", 8):
                # 跟踪丢失（达到 k_lost_frames），立即重新装入标称先验（history_types 保持不变）
                self.reseed_prior()
            else:
                # 仍允许在容限内使用上一帧平滑结果进行跟踪预测
                pass

        self.history_types.append(frame_type)

    def get_voted_type(self):
        """32 帧滑动多数表决最终类型。"""
        if not self.history_types:
            return "none"
        n_solid = sum(1 for t in self.history_types if t in ("solid", "double_yellow"))
        n_dash = sum(1 for t in self.history_types if t == "dashed")
        n_none = sum(1 for t in self.history_types if t == "none")
        if (n_solid + n_dash) == 0:
            return "none"
        if n_solid >= n_dash:
            # 判断是否主要为双黄
            n_dbl = sum(1 for t in self.history_types if t == "double_yellow")
            if (n_dbl << 1) > n_solid:
                return "double_yellow"
            return "solid"
        return "dashed"

    def predict_x(self, y_roi):
        """根据当前有效模型预测行 x 坐标。y_roi = y - y_top。"""
        if not self.valid or self.a_smooth_q16 is None:
            return None
        # x = (a * y_roi >> 16) + (b >> 4)
        x_pred = ((self.a_smooth_q16 * y_roi + 32768) >> 16) + ((self.b_smooth_q4 + 8) >> 4)
        return x_pred


class LaneFPGAModel:
    """逐行流式定点黄金模型。"""

    def __init__(self, params=None):
        if params is None:
            params = load_params()
        self.p = params
        self.y_top = self.p["y_top"]
        self.y_bot = self.p["y_bot"]
        self.n_rows = self.y_bot - self.y_top + 1
        self.x_c = self.p["x_c"]
        self.ego_x = self.p["ego_x"]

        self.left_state = LaneSideState("left", self.p)
        self.right_state = LaneSideState("right", self.p)
        self.reset()

    def reset(self):
        self.left_state.reset()
        self.right_state.reset()

    def _quantize_rgb565(self, img):
        """模拟 FPGA 窗口 0 的 RGB565 存储量化后展开。"""
        if img.ndim == 2 and img.dtype == np.uint16:
            rgb565_bin = img
            r5 = (rgb565_bin >> 11) & 0x1F
            g6 = (rgb565_bin >> 5) & 0x3F
            b5 = rgb565_bin & 0x1F
            r_q = (r5 << 3).astype(np.uint8)
            g_q = (g6 << 2).astype(np.uint8)
            b_q = (b5 << 3).astype(np.uint8)
            return r_q, g_q, b_q, rgb565_bin

        b = img[:, :, 0]
        g = img[:, :, 1]
        r = img[:, :, 2]
        r5 = (r >> 3).astype(np.uint16)
        g6 = (g >> 2).astype(np.uint16)
        b5 = (b >> 3).astype(np.uint16)
        rgb565_bin = (r5 << 11) | (g6 << 5) | b5
        # 展开回 8-bit（低位补 0）
        r_q = (r5 << 3).astype(np.uint8)
        g_q = (g6 << 2).astype(np.uint8)
        b_q = (b5 << 3).astype(np.uint8)
        return r_q, g_q, b_q, rgb565_bin

    def process_frame(self, frame_input):
        """处理一帧 1080p BGR 源图像或已量化的 (540, 960) uint16 RGB565 图像。

        返回单帧全部硬件流式处理数据与最终判决。
        """
        w, h = self.p["w"], self.p["h"]
        if frame_input.ndim == 2 and frame_input.dtype == np.uint16:
            frame_960 = frame_input
        else:
            # 1. 缩放到 960x540
            if frame_input.shape[1] != w or frame_input.shape[0] != h:
                frame_960 = cv2.resize(frame_input, (w, h), interpolation=cv2.INTER_AREA)
            else:
                frame_960 = frame_input.copy()

        # 2. RGB565 量化与灰度提取
        r_q, g_q, b_q, rgb565_bin = self._quantize_rgb565(frame_960)
        # 转为 int16 矩阵供高速流式切片
        r_q16 = r_q.astype(np.int16)
        g_q16 = g_q.astype(np.int16)
        b_q16 = b_q.astype(np.int16)
        G = (r_q16 + (g_q16 << 1) + b_q16) >> 2
        Gy = (r_q16 + g_q16) >> 1
        min_rg_all = np.minimum(r_q16, g_q16)

        # 3. 逐行处理初始化
        acc = {
            "left": {"n": 0, "sum_y": 0, "sum_yy": 0, "sum_x": 0, "sum_xy": 0, "sum_xx": 0},
            "right": {"n": 0, "sum_y": 0, "sum_yy": 0, "sum_x": 0, "sum_xy": 0, "sum_xx": 0},
        }
        row_candidates = []
        hits = {"left": np.zeros(self.n_rows, dtype=np.uint8), "right": np.zeros(self.n_rows, dtype=np.uint8)}
        double_flags = {"left": np.zeros(self.n_rows, dtype=np.uint8), "right": np.zeros(self.n_rows, dtype=np.uint8)}
        accepted_x = {"left": np.full(self.n_rows, -1, dtype=np.int32), "right": np.full(self.n_rows, -1, dtype=np.int32)}

        # 逐行扫描 ROI: y in [y_top, y_bot]
        y_top, y_bot = self.y_top, self.y_bot
        d_top, d_bot = self.p["d_top"], self.p["d_bot"]
        w_pred_top, w_pred_bot = self.p["w_pred_top"], self.p["w_pred_bot"]
        w_max_mult, w_max_add = self.p["w_max_mult"], self.p["w_max_add"]
        w_min = self.p.get("w_min", 1)
        white_delta = self.p["white_delta"]
        white_g_min = self.p["white_g_min"]
        yellow_r_min = self.p["yellow_r_min"]
        yellow_g_min = self.p["yellow_g_min"]
        yellow_b_diff = self.p["yellow_b_diff"]
        yellow_delta = self.p["yellow_delta"]
        double_mult = self.p["double_mult"]
        double_gap_min = self.p["double_gap_min"]

        for y in range(y_top, y_bot + 1):
            y_roi = y - y_top
            d_y = div_round(d_top * (y_bot - y_top) + y_roi * (d_bot - d_top), y_bot - y_top)
            w_max = int(round(w_max_mult * d_y + w_max_add))
            W_y = div_round(w_pred_top * (y_bot - y_top) + y_roi * (w_pred_bot - w_pred_top), y_bot - y_top)

            row_G = G[y]
            row_Gy = Gy[y]
            row_rq = r_q16[y]
            row_gq = g_q16[y]
            row_bq = b_q16[y]
            m_rg = min_rg_all[y]

            # 纯流式脊线与车道线像素判定
            cG = row_G[d_y : w - d_y]
            lG = row_G[0 : w - 2 * d_y]
            rG = row_G[2 * d_y : w]
            R_w = cG - np.maximum(lG, rG)

            cGy = row_Gy[d_y : w - d_y]
            lGy = row_Gy[0 : w - 2 * d_y]
            rGy = row_Gy[2 * d_y : w]
            R_y = cGy - np.maximum(lGy, rGy)

            crq = row_rq[d_y : w - d_y]
            cgq = row_gq[d_y : w - d_y]
            cbq = row_bq[d_y : w - d_y]
            min_rg = m_rg[d_y : w - d_y]

            is_white = (R_w >= white_delta) & (cG >= white_g_min)
            is_yellow = (crq >= yellow_r_min) & (cgq >= yellow_g_min) & ((cbq + yellow_b_diff) <= min_rg) & (R_y >= yellow_delta)
            is_lane = is_white | is_yellow

            # 高速连续脊线提取 Run
            n_p = len(is_lane)
            trans_up = np.where((is_lane[1:]) & (~is_lane[:-1]))[0] + 1
            starts = np.r_[0, trans_up] if is_lane[0] else trans_up
            trans_dn = np.where((~is_lane[1:]) & (is_lane[:-1]))[0] + 1
            ends = np.r_[trans_dn, n_p] if is_lane[-1] else trans_dn

            lens = ends - starts
            valid_mask = (lens >= w_min) & (lens <= w_max)
            run_centers = d_y + (starts[valid_mask] + ends[valid_mask] - 1) // 2
            runs = [int(rc) for rc in run_centers]

            # 4. 每行左右各选一个点，并判定 double
            left_runs = [rx for rx in runs if rx < self.x_c]
            right_runs = [rx for rx in runs if rx >= self.x_c]

            # 选择左侧候选点
            best_x_left = None
            if self.left_state.valid:
                x_pred = self.left_state.predict_x(y_roi)
                valid_cands = [rx for rx in left_runs if abs(rx - x_pred) <= W_y]
                if valid_cands:
                    best_x_left = min(valid_cands, key=lambda rx: abs(rx - x_pred))
            else:
                if left_runs:
                    best_x_left = max(left_runs)  # 左侧离 x_c 最近的点

            # 选择右侧候选点
            best_x_right = None
            if self.right_state.valid:
                x_pred = self.right_state.predict_x(y_roi)
                valid_cands = [rx for rx in right_runs if abs(rx - x_pred) <= W_y]
                if valid_cands:
                    best_x_right = min(valid_cands, key=lambda rx: abs(rx - x_pred))
            else:
                if right_runs:
                    best_x_right = min(right_runs)  # 右侧离 x_c 最近的点

            # 判定 double: 在车道线点附近 2*d(y) 范围内是否有另一条平行的 run
            dbl_thr = int(round(double_mult * d_y))
            dbl_left = False
            if best_x_left is not None:
                for rx in left_runs:
                    dist = abs(rx - best_x_left)
                    if double_gap_min <= dist <= dbl_thr:
                        dbl_left = True
                        break
            double_flags["left"][y_roi] = 1 if dbl_left else 0

            dbl_right = False
            if best_x_right is not None:
                for rx in right_runs:
                    dist = abs(rx - best_x_right)
                    if double_gap_min <= dist <= dbl_thr:
                        dbl_right = True
                        break
            double_flags["right"][y_roi] = 1 if dbl_right else 0

            # 累加器累加（无行缓冲，选出点后直接累加）
            if best_x_left is not None:
                hits["left"][y_roi] = 1
                accepted_x["left"][y_roi] = best_x_left
                acc["left"]["n"] += 1
                acc["left"]["sum_y"] += y_roi
                acc["left"]["sum_yy"] += y_roi * y_roi
                acc["left"]["sum_x"] += best_x_left
                acc["left"]["sum_xy"] += best_x_left * y_roi
                acc["left"]["sum_xx"] += best_x_left * best_x_left

            if best_x_right is not None:
                hits["right"][y_roi] = 1
                accepted_x["right"][y_roi] = best_x_right
                acc["right"]["n"] += 1
                acc["right"]["sum_y"] += y_roi
                acc["right"]["sum_yy"] += y_roi * y_roi
                acc["right"]["sum_x"] += best_x_right
                acc["right"]["sum_xy"] += best_x_right * y_roi
                acc["right"]["sum_xx"] += best_x_right * best_x_right

            row_candidates.append({
                "y": y,
                "y_roi": y_roi,
                "d_y": d_y,
                "w_max": w_max,
                "W_y": W_y,
                "runs": runs,
                "left_cand": best_x_left,
                "right_cand": best_x_right,
                "double_left": dbl_left,
                "double_right": dbl_right,
            })

        # 5. 帧末拟合解算 x = a*y + b
        fit_res = {}
        frame_types = {}
        for side in ("left", "right"):
            s_acc = acc[side]
            n = s_acc["n"]
            res = {
                "valid": False,
                "n": n,
                "a_q": 0,
                "b_q": 0,
                "a_flt": 0.0,
                "b_flt": 0.0,
                "rms": 999.0,
                "solid_run": 0,
                "double_count": int(double_flags[side].sum()),
            }

            # 有效条件 1: n >= N_min
            if n >= self.p["n_min"]:
                S_y = s_acc["sum_y"]
                S_yy = s_acc["sum_yy"]
                S_x = s_acc["sum_x"]
                S_xy = s_acc["sum_xy"]
                S_xx = s_acc["sum_xx"]

                D = n * S_yy - S_y * S_y
                if D > 0:
                    N_a = n * S_xy - S_x * S_y
                    N_b = S_x * S_yy - S_y * S_xy

                    # 定点解算: a 用 Q16, b 用 Q4
                    q_a = self.p.get("q_a", 16)
                    q_b = self.p.get("q_b", 4)
                    a_q = div_round(N_a << q_a, D)
                    b_q = div_round(N_b << q_b, D)

                    # 计算残差 SSE = S_xx - (N_a * S_xy + N_b * S_x) / D
                    # 纯定点表示: SSE_q = S_xx - ((a_q * S_xy) >> q_a) - ((b_q * S_x) >> q_b)
                    sse = S_xx - ((a_q * S_xy) >> q_a) - ((b_q * S_x) >> q_b)
                    if sse < 0:
                        sse = 0
                    rms = math.sqrt(sse / n)
                    res["a_q"] = a_q
                    res["b_q"] = b_q
                    res["a_flt"] = a_q / float(1 << q_a)
                    res["b_flt"] = b_q / float(1 << q_b)
                    res["rms"] = rms

                    # 有效条件 2: RMS <= R_max
                    # 有效条件 3: 斜率方向正确 (左线 a<0, 右线 a>0)
                    # 有效条件 4: 底行 x 在画面内 (0 <= x_bot <= w)
                    y_bot_roi = y_bot - y_top
                    x_bot = ((a_q * y_bot_roi + 32768) >> 16) + ((b_q + 8) >> 4)
                    x_top_fit = (b_q + 8) >> 4

                    slope_ok = (a_q < 0) if side == "left" else (a_q > 0)
                    range_ok = (0 <= x_bot < w) and (0 <= x_top_fit < w)
                    # 硬件等价定点残差比较: sse <= n * rms_max^2 (rms_max=16 -> 256)
                    rms_max_sq = int(round(self.p["rms_max"] ** 2))
                    rms_ok = (sse <= n * rms_max_sq)

                    if slope_ok and range_ok and rms_ok:
                        res["valid"] = True

            fit_res[side] = res

            # 6. 单帧虚实判定
            solid_y_top = self.p.get("solid_y_top", self.y_top)
            gap_tol = self.p.get("gap_tol", 0)

            start_idx = max(0, solid_y_top - self.y_top)
            eval_n_rows = max(1, self.y_bot - solid_y_top + 1)
            hits_slice = hits[side][start_idx:]

            # 最长连续命中段（带 gap_tol 断行容差）
            max_consec = 0
            cur_consec = 0
            cur_gap = 0
            for h_val in hits_slice:
                if h_val:
                    cur_gap = 0
                    cur_consec += 1
                    if cur_consec > max_consec:
                        max_consec = cur_consec
                else:
                    cur_gap += 1
                    if cur_gap > gap_tol:
                        cur_consec = 0
                        cur_gap = 0
            res["solid_run"] = max_consec
            solid_ratio = max_consec / float(eval_n_rows)
            dbl_ratio = res["double_count"] / float(self.n_rows)

            if not res["valid"]:
                f_type = "none"
            else:
                if dbl_ratio >= self.p["double_ratio_thr"]:
                    f_type = "double_yellow"
                elif solid_ratio >= self.p["solid_run_ratio"]:
                    f_type = "solid"
                else:
                    f_type = "dashed"
            frame_types[side] = f_type

        # 更新两侧状态跟踪器
        self.left_state.update_frame(fit_res["left"], frame_types["left"])
        self.right_state.update_frame(fit_res["right"], frame_types["right"])

        # 32 帧滑动多数表决
        voted_types = {
            "left": self.left_state.get_voted_type(),
            "right": self.right_state.get_voted_type(),
        }

        # 7. 车道偏离告警
        # 底行左右线 x_l, x_r
        y_bot_roi = y_bot - y_top
        x_l = self.left_state.predict_x(y_bot_roi)
        x_r = self.right_state.predict_x(y_bot_roi)
        M = self.p["depart_margin"]
        depart_warning = False
        if x_l is not None and (self.ego_x - x_l < M):
            depart_warning = True
        if x_r is not None and (x_r - self.ego_x < M):
            depart_warning = True

        return {
            "frame_960": frame_960,
            "rgb565_bin": rgb565_bin,
            "row_candidates": row_candidates,
            "acc": acc,
            "fit_res": fit_res,
            "frame_types": frame_types,
            "voted_types": voted_types,
            "depart_warning": depart_warning,
            "x_bot_l": x_l,
            "x_bot_r": x_r,
        }

    def decide(self, voted_type, force=False):
        """与 decide_ref.py 语义对齐的判决。"""
        # line_class
        if voted_type in ("white_dashed", "yellow_dashed", "dashed"):
            return "ALLOW"
        return "ALARM" if force else "KEEP"
