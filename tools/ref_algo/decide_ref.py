# -*- coding: utf-8 -*-
"""交通规则判决参考实现（仅使用 Python 标准库）。

规则口径（组委会口径 + 本项目约定）：
  1. 右转无右转灯时不受灯控：lane == "right" 且 right_free 为真，且灯态为
     none/off/unknown 时，直接判 GO（右转不受灯控）。
  2. 黄灯按红灯处理：灯态为 red 或 yellow 时按红灯逻辑处理（无强制行驶则
     STOP，强制行驶则 ALARM）。
  3. unknown 按停车处理：灯态为 unknown 时按红灯逻辑处理（无强制行驶则
     STOP，强制行驶则 ALARM）。
  4. 强制变道在非虚线时报警：decide_lane 中车道线不是虚线（dashed）且
     force 为真时判 ALARM；虚线一律 ALLOW。
"""

_SIG_RED = {"red", "yellow"}
_SIG_NONE = {"none", "off", "unknown"}


def decide_sig(lane, state, force_go, right_free=True):
    """信号灯判决。返回 "GO"/"STOP"/"ALARM"。

    lane 取 left/straight/right；state 取 red/yellow/green/none/off/unknown。
    """
    st = (state or "none").strip().lower()
    if lane == "right" and right_free and st in {"none", "off", "unknown"}:
        return "GO"
    if st in _SIG_RED:
        return "ALARM" if force_go else "STOP"
    if st == "unknown":
        return "ALARM" if force_go else "STOP"
    return "GO"


def line_class(line_type):
    """车道线分类。返回 "dashed"/"solid"/"none"。"""
    lt = (line_type or "none").strip().lower()
    if lt in {"white_dashed", "yellow_dashed"}:
        return "dashed"
    if lt in {"white_solid", "yellow_solid", "double_yellow"}:
        return "solid"
    return "none"


def decide_lane(side, line_type, force):
    """变道判决。返回 "ALLOW"/"KEEP"/"ALARM"。"""
    if line_class(line_type) == "dashed":
        return "ALLOW"
    return "ALARM" if force else "KEEP"


def leds(sig_decisions, lane_selected):
    """生成 4 位 LED 掩码：bit0 左、bit1 直、bit2 右、bit3 报警。

    sig_decisions 为 {lane: "GO"/"STOP"/"ALARM"}；所选车道判决为 GO 时点亮
    对应方向位，为 ALARM 时点亮 bit3（报警），否则不点亮。
    """
    bits = {"left": 0, "straight": 1, "right": 2}
    if lane_selected not in bits:
        return 0
    d = sig_decisions.get(lane_selected)
    if d == "GO":
        return 1 << bits[lane_selected]
    if d == "ALARM":
        return 1 << 3
    return 0
