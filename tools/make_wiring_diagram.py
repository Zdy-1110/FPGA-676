# -*- coding: utf-8 -*-
"""PCIe x4 被动转接板 REV_A 接线原理图（P1 主机卡边 <-> P2 盘古卡槽）
数据源: make_kicad_interposer.CONTACTS (已核实的 CEM x4 触点表)
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_kicad_interposer as g

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle
plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
plt.rcParams["axes.unicode_minus"] = False

C_DATA  = "#1565C0"   # PET/PER 差分对
C_CLK   = "#00897B"   # REFCLK
C_PERST = "#E65100"   # PERST#
C_GND   = "#2E7D32"   # GND
C_NC    = "#9E9E9E"   # 不连接
C_DET   = "#C62828"   # 在位检测
C_TP    = "#6A1B9A"   # 测试点

fig = plt.figure(figsize=(15.5, 18))
ax = fig.add_axes([0, 0, 1, 1]); ax.set_xlim(0, 100); ax.set_ylim(0, 116)
ax.axis("off")

# ---------------------------------------------------------------- 顶部块图
ax.text(50, 113.6, "PCIe x4 被动转接板 REV_A  接线原理图", ha="center", fontsize=21, weight="bold")
ax.text(50, 111.2, "P1 = 插入 OK3588-C(主机) PCIe x4 槽的卡边    P2 = 接收盘古 100Pro+ 金手指的卡槽 (UMAX 91613-110141D, 立创 C1509727)",
        ha="center", fontsize=10.5, color="#37474F")

bx, by, bh = 12, 97.5, 9.5   # 两个方块 y 基准
for x0, title, sub in ((bx, "OK3588-C 主机", "RK3588 · PCIe3.0 x4 RC\n标准 CEM 插槽 (open)"),
                       (76, "盘古 100Pro+", "MES2L676-100HP · EP\n标准 x4 金手指")):
    ax.add_patch(FancyBboxPatch((x0, by), 12, bh, boxstyle="round,pad=0.3",
                                fc="#E3F2FD" if x0 < 50 else "#E8F5E9", ec="#455A64", lw=1.4))
    ax.text(x0 + 6, by + bh - 2.6, title, ha="center", fontsize=12.5, weight="bold")
    ax.text(x0 + 6, by + 2.2, sub, ha="center", fontsize=8.6, color="#455A64")

def bundle(y, label, color, lw=2.6, ls="-"):
    ax.plot([bx + 12.3, 76 - 0.3], [y, y], color=color, lw=lw, ls=ls, solid_capstyle="round")
    ax.text(50, y + 0.55, label, ha="center", fontsize=9.3, color=color, weight="bold")

bundle(105.0, "PET0-3 +/- ×4   主机→盘古 (B 侧)", C_DATA)
bundle(103.2, "PER0-3 +/- ×4   盘古→主机 (A 侧)", C_DATA)
bundle(101.4, "REFCLK +/-  100MHz 差分时钟", C_CLK, 2.2)
bundle( 99.6, "PERST# 复位 (直通)", C_PERST, 2.0)
bundle( 97.8, "GND 共地 (电源 12V/3V3/3V3AUX 全部不连接)", C_GND, 2.0)
ax.text(50, 95.0, "不加 Switch / Retimer / 电平转换 / AC 耦合(主机端已有 220nF)；转接板卡边 A1-B31 短接 = x4 卡在位检测",
        ha="center", fontsize=9.5, color="#C62828")

# ---------------------------------------------------------------- 逐触点连线表
TOP, RH = 90.5, 1.06           # 表首行 y 与行高
XL, XR = 30, 70                # 左右触点文本 x
XW = XL - 6                    # 线起点

def row_y(i):
    return TOP - i * RH

def nc_mark(x, y):
    ax.plot([x - 0.55, x + 0.55], [y - 0.28, y + 0.28], color=C_NC, lw=1.4)
    ax.plot([x - 0.55, x + 0.55], [y + 0.28, y - 0.28], color=C_NC, lw=1.4)

ax.text(6, 91.6, "P1 触点", fontsize=10, weight="bold", color="#263238")
ax.text(94, 91.6, "P2 触点", fontsize=10, weight="bold", color="#263238", ha="right")
ax.text(XL, 92.4, "A 侧  （方向：盘古 PET → 主机）", fontsize=11.5, weight="bold", color="#0D47A1")
ax.text(XR, 92.4, "", fontsize=11)

row_of_lane_label = {}
i = 0
last_lane_top = {}
for idx, name in enumerate(g.ORDER):
    y = row_y(idx)
    row = g.BY_NAME[name]
    p1n, p2n = g.p1_net(name), g.p2_net(name)
    side = name[0]
    # 每侧画触点名 + 功能
    ax.text(XL - 1.2 if side == "A" else XL - 1.2, y, f"{name}", ha="right", fontsize=8.8,
            family="monospace", color="#263238",
            weight="bold" if p1n not in (None, "GND") else "normal")
    ax.text(XR + 1.2, y, f"{name}", ha="left", fontsize=8.8, family="monospace", color="#263238",
            weight="bold" if p2n not in (None, "GND") else "normal")
    ax.text(XL - 7.5, y, row["func"][:14], ha="right", fontsize=7.6, color="#607D8B")
    ax.text(XR + 7.5, y, row["func"][:14], ha="left", fontsize=7.6, color="#607D8B")

    if name in ("A1", "B31"):      # 在位检测: P1 接地, P2 不接
        ax.plot([XW, XL - 0.7], [y, y], color=C_DET, lw=2.2)
        ax.plot([XR + 0.7, XR + 6], [y, y], color=C_NC, lw=1.2, ls=(0, (3, 2)))
        nc_mark(XR + 6.6, y)
        ax.text(50, y + 0.02, "P1 卡边已短接 GND = x4 在位检测；盘古侧不并接", ha="center",
                fontsize=7.8, color=C_DET)
    elif name in ("B11", "B12"):   # WAKE/CLKREQ -> 测试点, P2 侧不接
        ax.plot([XW, XL - 0.7], [y, y], color=C_TP, lw=2.0)
        tp = "TP5 (WAKE#)" if name == "B11" else "TP6 (CLKREQ#)"
        ax.plot([XL + 0.8, 48], [y, y], color=C_TP, lw=1.0, ls=(0, (2, 2)))
        ax.text(48.5, y, tp, fontsize=8.2, color=C_TP, ha="left", va="center")
        ax.plot([XR + 0.7, XR + 6], [y, y], color=C_NC, lw=1.2, ls=(0, (3, 2)))
        nc_mark(XR + 6.6, y)
    elif p1n is None:              # 电源/JTAG/保留: 两侧都不接
        nc_mark((XL + XR) / 2 - 1.5, y); nc_mark((XL + XR) / 2 + 1.5, y)
        ax.plot([XW, XL - 0.7], [y, y], color=C_NC, lw=0.9, ls=(0, (2, 2)))
        ax.plot([XR + 0.7, XR + 6], [y, y], color=C_NC, lw=0.9, ls=(0, (2, 2)))
        ax.text(50, y + 0.02, "NC", ha="center", fontsize=7.5, color=C_NC)
    else:
        color = C_GND if p1n == "GND" else (C_CLK if "REFCLK" in p1n else
                (C_PERST if "PERST" in p1n else C_DATA))
        lw = 1.6 if p1n == "GND" else 2.4
        ax.plot([XW, XR + 6], [y, y], color=color, lw=lw, solid_capstyle="round")
        if p1n != "GND":
            ax.text(50, y + 0.02, p1n, ha="center", fontsize=7.6, color=color, weight="bold")

# 分组括号标注
def brace(i0, i1, label, color):
    y0, y1 = row_y(i0) + 0.32, row_y(i1) - 0.32
    ax.plot([2.2, 2.2], [y0, y1], color=color, lw=1.6)
    ax.plot([2.2, 2.9], [y0, y0], color=color, lw=1.6)
    ax.plot([2.2, 2.9], [y1, y1], color=color, lw=1.6)
    ax.text(1.4, (y0 + y1) / 2, label, rotation=90, ha="center", va="center",
            fontsize=8.6, color=color, weight="bold")

order_idx = {n: k for k, n in enumerate(g.ORDER)}
for lane in range(4):
    i0 = order_idx[f"A{16 + lane * 4 + (0 if lane == 0 else 1)}"] if False else None
# 手工定位: PER0=A16/17, PER1=A21/22, PER2=A25/26, PER3=A29/30
for i0, i1, lab in ((order_idx["A16"], order_idx["A17"], "LANE0 (卡→主机)"),
                    (order_idx["A21"], order_idx["A22"], "LANE1 (卡→主机)"),
                    (order_idx["A25"], order_idx["A26"], "LANE2 (卡→主机)"),
                    (order_idx["A29"], order_idx["A30"], "LANE3 (卡→主机)"),
                    (order_idx["B14"], order_idx["B15"], "LANE0 (主机→卡)"),
                    (order_idx["B19"], order_idx["B20"], "LANE1 (主机→卡)"),
                    (order_idx["B23"], order_idx["B24"], "LANE2 (主机→卡)"),
                    (order_idx["B27"], order_idx["B28"], "LANE3 (主机→卡)"),
                    (order_idx["A13"], order_idx["A14"], "REFCLK 100MHz"),
                    (order_idx["B31"], order_idx["A1"], "")):
    if lab:
        brace(i0, i1, lab, C_DATA if "LANE" in lab else C_CLK)

# 分隔: A 侧块与 B 侧块之间画一条虚线
yb = (row_y(order_idx["A32"]) + row_y(order_idx["B1"])) / 2
ax.plot([4, 96], [yb, yb], color="#B0BEC5", lw=0.9, ls=(0, (6, 4)))
ax.text(50, yb + 0.42, "B 侧  （方向：主机 PET → 盘古）", ha="center", fontsize=11.5,
        weight="bold", color="#1B5E20")

# ---------------------------------------------------------------- 图例与要点
yL = row_y(len(g.ORDER)) - 2.2
leg = [(C_DATA, "PET/PER 差分对 (1:1 直通, 不换对不换极性)"),
       (C_CLK, "REFCLK+/- 差分时钟 (直通; 上电前须万用表实测盘古 F13/E13 连续性)"),
       (C_PERST, "PERST# 复位 (直通)"),
       (C_GND, "GND (显式地桥接线 + 地总线 + 51 个缝合过孔, 不依赖铺铜)"),
       (C_DET, "在位检测: P1 卡边 A1-B31 短接, 盘古侧 PRSNT 不并接"),
       (C_TP,  "测试点: WAKE#/CLKREQ# 默认不使用, 仅引到 TP5/TP6"),
       (C_NC,  "不连接 NC: 12V/3.3V/3.3VAUX 全部隔离; JTAG/SMBUS/保留脚悬空; B17 悬空")]
for k, (cc, txt) in enumerate(leg):
    yy = yL - k * 1.7
    ax.plot([8, 12], [yy, yy], color=cc, lw=2.6, solid_capstyle="round")
    ax.text(13, yy, txt, fontsize=9.2, color="#263238", va="center")

notes = ("制板/上电前必查:  ① 万用表实测 P2.A13/A14 到盘古 REFCLK (手册口径 F13/E13) 连通性  "
         "② 盘古 12V 隔离未证实 -> 主机与盘古必须各自独立供电, 共地但共不了电  "
         "③ 91613 触点网格到货后实测一次  ④ 反插只会导致不枚举(安全失效), 但方向丝印务必核对")
ax.add_patch(FancyBboxPatch((8, yL - 13.6), 84, 3.0, boxstyle="round,pad=0.3",
                            fc="#FFF8E1", ec="#F9A825", lw=1.2))
ax.text(50, yL - 12.1, notes, ha="center", fontsize=9.0, color="#5D4037", wrap=True)

out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "PCIe中间件_REV_A_接线图.png")
fig.savefig(out, dpi=150, facecolor="white")
print("saved:", out)
