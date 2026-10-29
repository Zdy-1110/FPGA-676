# -*- coding: utf-8 -*-
"""FPGA 定点流式斑马线检测黄金模型。

严格遵循 FPGA 逐行流式、零行缓冲设计规范：
- 输入：单帧 960x540 RGB565（小端 uint16）
- 行统计：单行遍历，无整帧/多行缓存，纯整数判决路径
- 帧统计：垂直方向跨行状态寄存器累加（允许 <= 2 行间断）
- 时间滤波：时间迟滞（3 帧置位，6 帧清零）
"""

import json
import os
import numpy as np

DEFAULT_PARAMS_PATH = os.path.join(os.path.dirname(__file__), "params.json")


def load_params(path: str = None) -> dict:
    if path is None:
        path = DEFAULT_PARAMS_PATH
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def row_stats(row_rgb565: np.ndarray, p: dict) -> dict:
    """逐行流式特征统计。

    完全模拟硬件行内像素流：
    - RGB565 解开至 8-bit 量化分量
    - 白色判据：r>=v_min, g>=v_min, b>=v_min, max(r,g,b)-min(r,g,b) <= c_max
    - 行内一维游程状态机：合并 <= gap_max 的暗间隙
    - 丢弃贴左右边缘（edge_margin）的游程
    - 过滤 [w_min, w_max] 范围外的游程
    - 纯整数规整性判决：(max_w - min_w) * 100 * cnt <= reg_pct * sum_w
    """
    v_min = p["v_min"]
    c_max = p["c_max"]
    gap_max = p["gap_max"]
    edge_margin = p["edge_margin"]
    w_min = p["w_min"]
    w_max = p["w_max"]
    n_min = p["n_min"]
    reg_pct = p["reg_pct"]
    w = p.get("w", 960)

    # 1. 解开 RGB565
    row_u16 = row_rgb565.astype(np.uint16)
    r5 = (row_u16 >> 11) & 0x1F
    g6 = (row_u16 >> 5) & 0x3F
    b5 = row_u16 & 0x1F
    r8 = (r5 << 3).astype(np.int16)
    g8 = (g6 << 2).astype(np.int16)
    b8 = (b5 << 3).astype(np.int16)

    max_c = np.maximum(np.maximum(r8, g8), b8)
    min_c = np.minimum(np.minimum(r8, g8), b8)
    is_white = ((r8 >= v_min) & (g8 >= v_min) & (b8 >= v_min) & ((max_c - min_c) <= c_max)).astype(np.uint8)
    white_px = int(np.sum(is_white))

    # 2. 模拟行内硬件一维游程状态机
    # 状态：cur_w (当前游程宽度), gap (当前暗间隙计数), start_x (当前游程起点)
    runs = []  # [(start_x, end_x, width)]
    cur_w = 0
    gap = 0
    start_x = 0

    for x in range(w):
        if is_white[x]:
            if cur_w == 0:
                start_x = x
            cur_w += gap + 1
            gap = 0
        else:
            if cur_w > 0:
                gap += 1
                if gap > gap_max:
                    end_x = x - gap
                    runs.append((start_x, end_x, cur_w))
                    cur_w = 0
                    gap = 0

    if cur_w > 0:
        end_x = w - 1 - gap
        runs.append((start_x, end_x, cur_w))

    runs_cnt = len(runs)

    # 3. 过滤边缘游程与宽度过滤 [w_min, w_max]
    valid_runs = []
    for s, e, width in runs:
        if s > edge_margin and e < (w - 1 - edge_margin):
            if w_min <= width <= w_max:
                valid_runs.append((s, e, width))

    runs_valid = len(valid_runs)
    cand = 0
    mean_w = 0
    max_w = 0
    min_w = 0

    # 4. 宽度规整性判决（纯整数）及新增物理约束 (跨度/占空比/间隙)
    if runs_valid >= n_min:
        valid_widths = [v[2] for v in valid_runs]
        min_w = min(valid_widths)
        max_w = max(valid_widths)
        sum_w = sum(valid_widths)
        mean_w = sum_w // runs_valid

        # 4.1 规整度判决：(max_w - min_w) * 100 * runs_valid <= reg_pct * sum_w
        if (max_w - min_w) * 100 * runs_valid <= reg_pct * sum_w:
            cand = 1

            # 4.2 跨度约束 span_ratio
            span_ratio = p.get("span_ratio", None)
            span = valid_runs[-1][1] - valid_runs[0][0]
            if span_ratio is not None:
                span_thr_q10 = int(round(span_ratio * 1000))
                if span * 1000 < span_thr_q10 * w:
                    cand = 0

            # 4.3 占空比约束 duty_min / duty_max
            duty_min = p.get("duty_min", None)
            duty_max = p.get("duty_max", None)
            if cand == 1 and (duty_min is not None or duty_max is not None):
                if duty_min is not None:
                    d_min_q7 = int(round(duty_min * 100))
                    if sum_w * 100 < d_min_q7 * span:
                        cand = 0
                if duty_max is not None:
                    d_max_q7 = int(round(duty_max * 100))
                    if sum_w * 100 > d_max_q7 * span:
                        cand = 0

            # 4.4 相邻间隙约束 gap_min_w / gap_max_w
            gap_min_w = p.get("gap_min_w", None)
            gap_max_w = p.get("gap_max_w", None)
            if cand == 1 and (gap_min_w is not None or gap_max_w is not None):
                for j in range(runs_valid - 1):
                    g_val = valid_runs[j + 1][0] - valid_runs[j][1]
                    if gap_min_w is not None and g_val < gap_min_w:
                        cand = 0
                        break
                    if gap_max_w is not None and g_val > gap_max_w:
                        cand = 0
                        break

    return {
        "runs": runs,
        "runs_cnt": runs_cnt,
        "runs_valid": runs_valid,
        "white_px": white_px,
        "cand": cand,
        "mean_w": mean_w,
        "max_w": max_w,
        "min_w": min_w,
    }


def frame_stats(rgb565: np.ndarray, p: dict) -> dict:
    """整帧逐行流式判决。

    仅扫描 [y_top, y_bot) 的 ROI 行。
    跨行跟踪状态寄存器：
    - cur_cont: 当前连续候选行数
    - gap_rows: 当前遇到的非候选行间隙
    - max_cont: 最大连续候选行数
    """
    y_top = p["y_top"]
    y_bot = p["y_bot"]
    r_min = p["r_min"]
    cont_min = p["cont_min"]

    rows = []
    cand_y_list = []

    # 跨行状态寄存器
    cur_cont = 0
    gap_rows = 0
    max_cont = 0

    for row_idx, y in enumerate(range(y_top, y_bot)):
        r_stat = row_stats(rgb565[y], p)
        r_stat["row"] = row_idx
        r_stat["y"] = y
        rows.append(r_stat)

        if r_stat["cand"] == 1:
            cand_y_list.append(y)
            if gap_rows <= 2:
                cur_cont += 1
            else:
                cur_cont = 1
            gap_rows = 0
            if cur_cont > max_cont:
                max_cont = cur_cont
        else:
            gap_rows += 1
            if gap_rows > 2:
                cur_cont = 0

    n_rows = len(cand_y_list)
    y_min = cand_y_list[0] if cand_y_list else -1
    y_max = cand_y_list[-1] if cand_y_list else -1

    # 帧级原始判决
    zebra_raw = bool((n_rows >= r_min) and (max_cont >= cont_min))

    return {
        "rows": rows,
        "zebra_raw": zebra_raw,
        "y_min": y_min,
        "y_max": y_max,
        "n_rows": n_rows,
        "max_cont": max_cont,
    }


class ZebraFilter:
    """时间迟滞滤波器。

    硬件逻辑：
    - 连续 hyst_pos 帧检测到置位 1
    - 连续 hyst_neg 帧未检测到清零 0
    """

    def __init__(self, hyst_pos: int = 3, hyst_neg: int = 6):
        self.hyst_pos = hyst_pos
        self.hyst_neg = hyst_neg
        self.reset()

    def reset(self):
        self.consec_pos = 0
        self.consec_neg = 0
        self.state = 0

    def update(self, raw_val: bool) -> int:
        if raw_val:
            self.consec_pos += 1
            self.consec_neg = 0
            if self.consec_pos >= self.hyst_pos:
                self.state = 1
        else:
            self.consec_neg += 1
            self.consec_pos = 0
            if self.consec_neg >= self.hyst_neg:
                self.state = 0
        return self.state
