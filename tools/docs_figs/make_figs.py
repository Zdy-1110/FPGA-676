"""
make_figs.py - 论文/技术文档高质量技术插图生成脚本
包含 6 张技术框图与状态机图，满足 300 dpi、统一配色、无重叠自检要求。
"""

import os
import sys
import matplotlib.pyplot as plt
import matplotlib.patches as patches
import matplotlib.font_manager as fm
from PIL import Image

# ---------------------------------------------------------
# 字体与配色规范配置
# ---------------------------------------------------------
FONT_PATH_REG = r"C:\Windows\Fonts\msyh.ttc"
FONT_PATH_BOLD = r"C:\Windows\Fonts\msyhbd.ttc"

font_reg = fm.FontProperties(fname=FONT_PATH_REG)
font_bold = fm.FontProperties(fname=FONT_PATH_BOLD)

# 配色定义
COLOR_BG = "#FFFFFF"            # 画布纯白背景
COLOR_BORDER = "#334155"        # 深灰框线 (Slate-700)
COLOR_CARD_BG = "#F1F5F9"       # 浅灰填充 (Slate-100)
COLOR_CONTAINER_BG = "#F8FAFC"  # 容器浅底 (Slate-50)
COLOR_CYAN = "#0E7490"          # 强调青色 (Cyan-700)
COLOR_CYAN_BG = "#E0F2FE"       # 浅青背景 (Cyan-100)
COLOR_ORANGE = "#C2410C"        # 强调橙色 (Orange-700)
COLOR_ORANGE_BG = "#FFEDD5"     # 浅橙背景 (Orange-100)
COLOR_TEXT_MAIN = "#0F172A"     # 正文主色 (Slate-900)
COLOR_TEXT_MUTED = "#475569"    # 次要文字 (Slate-600)

OUTPUT_DIR = "docs/figs"
FIG_SIZE = (11.5, 6.5)          # 宽约 11.5 英寸，高 6.5 英寸
DPI = 300                       # 300 dpi 输出，宽 3450 px >= 3000 px


# ---------------------------------------------------------
# 通用绘图辅助函数
# ---------------------------------------------------------
def create_base_canvas():
    fig, ax = plt.subplots(figsize=FIG_SIZE, dpi=DPI)
    fig.patch.set_facecolor(COLOR_BG)
    fig.subplots_adjust(0, 0, 1, 1)
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 100)
    ax.axis("off")
    return fig, ax


def draw_box(ax, x, y, w, h, bg_color=COLOR_CARD_BG, border_color=COLOR_BORDER, lw=1.2, radius=0.8):
    """绘制圆角方框，坐标 (x, y) 为左下角，w 为宽度，h 为高度"""
    rect = patches.FancyBboxPatch(
        (x, y), w, h,
        boxstyle=f"round,pad={radius},rounding_size={radius}",
        facecolor=bg_color,
        edgecolor=border_color,
        linewidth=lw,
        zorder=2
    )
    ax.add_patch(rect)
    return rect


def draw_arrow(ax, start, end, color=COLOR_BORDER, lw=1.5, ls="-", style="->", mutation_scale=15):
    """绘制 FancyArrowPatch 箭头"""
    arrow = patches.FancyArrowPatch(
        posA=start,
        posB=end,
        arrowstyle=style,
        mutation_scale=mutation_scale,
        color=color,
        linewidth=lw,
        linestyle=ls,
        zorder=3
    )
    ax.add_patch(arrow)
    return arrow


def draw_header(ax, title, subtitle, fig_num_str):
    """绘制顶部标题与右上角图号"""
    ax.text(3.5, 98.2, title, fontproperties=font_bold, size=14.5, color=COLOR_TEXT_MAIN, ha="left", va="top")
    if subtitle:
        ax.text(3.5, 94.2, subtitle, fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="left", va="top")
    ax.text(96.5, 98.2, fig_num_str, fontproperties=font_bold, size=12, color=COLOR_CYAN, ha="right", va="top")


# ---------------------------------------------------------
# 自检函数 check_bboxes
# ---------------------------------------------------------
def check_bboxes(fig, name):
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    W, H = fig.get_size_inches() * fig.dpi
    tol = 0.02  # 2% 容差

    # 遍历所有可见且非空的 Text 与 Annotation
    all_texts = []
    for ax in fig.axes:
        for t in ax.texts:
            if t.get_visible() and t.get_text().strip():
                all_texts.append(t)
    for t in fig.texts:
        if t.get_visible() and t.get_text().strip():
            all_texts.append(t)

    # 1. 断言在 [0, 1] 窗口坐标内 (允许 2% 容差)
    boxes = []
    for t in all_texts:
        bb = t.get_window_extent(renderer)
        x0 = bb.x0 / W
        y0 = bb.y0 / H
        x1 = bb.x1 / W
        y1 = bb.y1 / H

        if x0 < -tol or y0 < -tol or x1 > 1.0 + tol or y1 > 1.0 + tol:
            print(f"FAIL {name}: text out of bounds: '{t.get_text()[:30]}' at ({x0:.3f}, {y0:.3f}, {x1:.3f}, {y1:.3f})")
            sys.exit(4)
        boxes.append((t, x0, y0, x1, y1))

    # 2. 断言两两不重叠 (允许 2% 容差)
    n = len(boxes)
    for i in range(n):
        ta, ax0, ay0, ax1, ay1 = boxes[i]
        area_a = (ax1 - ax0) * (ay1 - ay0)
        for j in range(i + 1, n):
            tb, bx0, by0, bx1, by1 = boxes[j]
            area_b = (bx1 - bx0) * (by1 - by0)

            inter_w = max(0.0, min(ax1, bx1) - max(ax0, bx0))
            inter_h = max(0.0, min(ay1, by1) - max(ay0, by0))
            inter_area = inter_w * inter_h

            if inter_area > 0:
                min_area = min(area_a, area_b)
                ratio = inter_area / min_area if min_area > 0 else 0
                if ratio > 0.02:
                    print(f"FAIL {name}: text overlap ({ratio:.1%}): '{ta.get_text()[:25]}' vs '{tb.get_text()[:25]}'")
                    sys.exit(4)

    print(f"OK {name}")


# ---------------------------------------------------------
# 图 1: 系统总体框图
# ---------------------------------------------------------
def build_fig1():
    fig, ax = create_base_canvas()
    draw_header(ax, "车载 ADAS 异构计算平台系统总体框图",
                "瑞芯微 RK3568 SoC 与紫光同创盘古 100Pro+ (PG2L100H) 软硬紧耦合架构",
                "Fig. 1  系统总体框图")

    # 左侧输入源
    draw_box(ax, 3.5, 66.0, 16.0, 22.0)
    ax.text(11.5, 77.0, "3× USB 摄像头输入\n(/dev/video17 / 19 / 21)\n前视 / 左后视 / 右后视\n视频吞吐: 30 fps",
            fontproperties=font_reg, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 3.5, 38.0, 16.0, 22.0)
    ax.text(11.5, 49.0, "FMC 双目 CMOS\n(OV5640 ×2 专用子卡)\n专用高速差分通道\n双目同步像素输入",
            fontproperties=font_reg, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 3.5, 14.0, 16.0, 18.0)
    ax.text(11.5, 23.0, "键盘 / 按键模块\n(KEY0 ~ KEY4 矩阵)\n驾驶员意图 / 模式切换\n透视变换标定触发",
            fontproperties=font_reg, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # RK3568 SoC 容器
    draw_box(ax, 23.5, 26.0, 24.5, 62.0, bg_color=COLOR_CONTAINER_BG, border_color=COLOR_CYAN, lw=1.5)
    ax.text(35.75, 85.0, "瑞芯微 RK3568 主控 SoC (Linux 4.19)",
            fontproperties=font_bold, size=11.5, color=COLOR_CYAN, ha="center", va="center")

    draw_box(ax, 25.5, 70.0, 20.5, 11.0)
    ax.text(35.75, 75.5, "MPP 硬件解码器\n(H.264/H.265 硬解 NV12 零拷贝)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 25.5, 56.0, 20.5, 11.0)
    ax.text(35.75, 61.5, "RGA 2D 硬件图形引擎\n(裁剪 / 缩放 960×540 / 格式转换)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 25.5, 42.0, 20.5, 11.0, bg_color=COLOR_ORANGE_BG, border_color=COLOR_ORANGE)
    ax.text(35.75, 47.5, "NPU 神经网络推理加速\n(YOLO INT8 定点化，耗时 17.55 ms)",
            fontproperties=font_bold, size=10.0, color=COLOR_ORANGE, ha="center", va="center")

    draw_box(ax, 25.5, 28.0, 20.5, 11.0)
    ax.text(35.75, 33.5, "ADAS 决策引擎 (tl_det & 状态机)\n菜单 UI (mode_select / usb_menu)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # PG2L100H FPGA 容器
    draw_box(ax, 56.0, 14.0, 25.0, 74.0, bg_color=COLOR_CONTAINER_BG, border_color=COLOR_CYAN, lw=1.5)
    ax.text(68.5, 85.0, "紫光同创 PG2L100H FPGA 视频中枢",
            fontproperties=font_bold, size=11.5, color=COLOR_CYAN, ha="center", va="center")

    draw_box(ax, 58.0, 70.0, 21.0, 11.0)
    ax.text(68.5, 75.5, "PCIe 端点 & 门铃 DMA 控制器\n(Scatter-Gather 突发传输拉取)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 58.0, 56.0, 21.0, 11.0)
    ax.text(68.5, 61.5, "DDR3 Hub 仲裁器 & 四宫格显示\n(32-bit @ 400 MHz，独立 Commit)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 58.0, 42.0, 21.0, 11.0)
    ax.text(68.5, 47.5, "流式算法核 (rt_lane_det / rt_zebra_det)\n(单遍光栅流水线，车道线与斑马线)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 58.0, 28.0, 21.0, 11.0)
    ax.text(68.5, 33.5, "多图层 OSD 引擎 (rt_osd & rt_osd_ctl)\n扩展寄存器池 (rt_ext_regs & rt_keys)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 58.0, 16.0, 21.0, 9.5)
    ax.text(68.5, 20.75, "物理按键消抖 → 0x844 寄存器\n(按键事件序列号与长按识别)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 右侧 HDMI 显示输出
    draw_box(ax, 85.0, 52.0, 11.5, 20.0)
    ax.text(90.75, 62.0, "HDMI 监控显示器\n(1920×1080@60Hz)\nMS7210 发送芯片驱动\n全硬件无撕裂输出",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 箭头与连接线
    # 1. USB -> RK3568 (数据流 实线)
    draw_arrow(ax, (19.5, 77.0), (25.5, 75.5), color=COLOR_BORDER, lw=1.6)
    ax.text(22.0, 78.5, "UVC 裸流", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="center", va="bottom")

    # 2. PCIe 数据流 (实线 896 MB/s)
    draw_arrow(ax, (48.0, 75.5), (58.0, 75.5), color=COLOR_ORANGE, lw=2.0)
    ax.text(51.8, 73.4, "896 MB/s", fontproperties=font_bold, size=9.0,
            color=COLOR_ORANGE, ha="center", va="top")

    # 3. MMIO 控制流 (虚线)
    draw_arrow(ax, (48.0, 61.5), (58.0, 61.5), color=COLOR_BORDER, lw=1.4, ls="--", style="<->")
    ax.text(51.8, 63.4, "MMIO", fontproperties=font_reg, size=9.0,
            color=COLOR_TEXT_MUTED, ha="center", va="bottom")

    # 4. FMC OV5640 -> FPGA 算法核：走 RK 面板下方与两面板之间的空走廊，避免穿过 RK 面板
    fmc_path = [(19.5, 44.0), (21.3, 44.0), (21.3, 13.2), (52.0, 13.2), (52.0, 47.5)]
    ax.plot([p[0] for p in fmc_path], [p[1] for p in fmc_path],
            color=COLOR_CYAN, lw=1.8, solid_capstyle="round", zorder=3)
    draw_arrow(ax, (52.0, 47.5), (58.0, 47.5), color=COLOR_CYAN, lw=1.8)
    ax.text(36.75, 15.4, "FMC 双目 OV5640 像素流直连 FPGA 视频中枢",
            fontproperties=font_bold, size=9.0, color=COLOR_CYAN, ha="center", va="bottom")

    # 5. 按键模块 -> 0x844 -> FPGA (虚线 控制)
    draw_arrow(ax, (19.5, 23.0), (58.0, 20.75), color=COLOR_BORDER, lw=1.4, ls="--")

    # 6. FPGA -> HDMI (实线 数据流)
    draw_arrow(ax, (81.0, 62.0), (85.0, 62.0), color=COLOR_BORDER, lw=1.6)

    # 底部关键指标与图例卡片
    draw_box(ax, 23.5, 4.0, 73.0, 7.5, bg_color=COLOR_CARD_BG, border_color=COLOR_BORDER)
    ax.text(60.0, 7.75, "关键指标: PCIe 实测 896 MB/s | 多路吞吐 30 fps | NPU推理时延 17.55 ms (中位数)\n图例规范: ── 实线: 高速视频数据流    ┈ 虚线: 硬件控制/状态/按键信号",
            fontproperties=font_bold, size=10.0, color=COLOR_CYAN, ha="center", va="center")

    return fig


# ---------------------------------------------------------
# 图 2: 软硬协同零拷贝数据流
# ---------------------------------------------------------
def build_fig2():
    fig, ax = create_base_canvas()
    draw_header(ax, "软硬协同全链路零拷贝数据流拓扑",
                "消除 CPU 拷贝瓶颈：从视频硬解、硬件缩放、门铃 DMA 到 FPGA 逐行合成显示",
                "Fig. 2  软硬协同零拷贝数据流")

    # 顶部横幅
    draw_box(ax, 3.5, 85.5, 65.5, 5.0, bg_color=COLOR_CYAN_BG, border_color=COLOR_CYAN, lw=1.2)
    ax.text(36.25, 88.0, "★ 全链路零拷贝：每一级数据流动均在专用硬件加速引擎间接力，全程不经过 CPU 内存拷贝",
            fontproperties=font_bold, size=10.0, color=COLOR_CYAN, ha="center", va="center")

    # 第一排 (SoC 侧) 4 个阶段
    stages_row1 = [
        ("U盘 mp4\n(外部视频文件源)", 3.5),
        ("MPP 硬解(NV12)\n(硬解输出物理连续帧)", 20.5),
        ("RGA 缩放/格式转换\n(下采样至 960×540)", 37.5),
        ("DMA-BUF(CMA)\n(256MB 连续物理内存)", 54.5)
    ]
    for text, x in stages_row1:
        draw_box(ax, x, 62.0, 14.5, 18.0)
        ax.text(x + 7.25, 71.0, text, fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 第一排箭头及上方"不经过 CPU 内存拷贝"标注
    draw_arrow(ax, (18.0, 71.0), (20.5, 71.0), color=COLOR_CYAN, lw=1.6)

    draw_arrow(ax, (35.0, 71.0), (37.5, 71.0), color=COLOR_CYAN, lw=1.6)

    draw_arrow(ax, (52.0, 71.0), (54.5, 71.0), color=COLOR_CYAN, lw=1.6)

    # 跨层中转箭头 (从 CMA 到 门铃 DMA)，含义由两端方框与顶部横幅说明，不再压字
    draw_arrow(ax, (61.75, 62.0), (10.75, 45.0), color=COLOR_ORANGE, lw=1.8)

    # 第二排 (FPGA 侧) 4 个阶段
    stages_row2 = [
        ("门铃 DMA\n(0x190/0x194/\n0x198/0x19C)", 3.5),
        ("FPGA DDR 帧存\n(4 组解耦物理缓冲)", 20.5),
        ("四宫格排版\n(逐行硬件光栅扫描)", 37.5),
        ("HDMI\n(1080P@60Hz 监控屏)", 54.5)
    ]
    for text, x in stages_row2:
        draw_box(ax, x, 27.0, 14.5, 18.0)
        ax.text(x + 7.25, 36.0, text, fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 第二排箭头（接力关系已在顶部横幅统一说明，不再重复标注，避免压线）
    draw_arrow(ax, (18.0, 36.0), (20.5, 36.0), color=COLOR_CYAN, lw=1.6)
    draw_arrow(ax, (35.0, 36.0), (37.5, 36.0), color=COLOR_CYAN, lw=1.6)
    draw_arrow(ax, (52.0, 36.0), (54.5, 36.0), color=COLOR_CYAN, lw=1.6)

    # 底部门铃控制说明（拆短行，避免超出卡片边界）
    draw_box(ax, 3.5, 7.5, 65.5, 15.0, bg_color=COLOR_CARD_BG, border_color=COLOR_BORDER)
    ax.text(36.25, 15.0,
            "门铃寄存器: slot0 → 0x190 | slot1 → 0x194\n"
            "slot2 → 0x198 | slot3 → 0x19C\n"
            "SoC 仅写物理地址，FPGA DMA 自主发起总线突发读\n"
            "全链路 0 CPU Memcpy、0 画面撕裂",
            fontproperties=font_reg, size=9.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 右侧槽位格式与带宽核算卡片
    draw_box(ax, 71.0, 7.5, 25.5, 83.0, bg_color=COLOR_CONTAINER_BG, border_color=COLOR_CYAN, lw=1.5)
    ax.text(83.75, 86.5, "槽位格式与总线带宽占比评估",
            fontproperties=font_bold, size=11.5, color=COLOR_CYAN, ha="center", va="center")

    draw_box(ax, 72.5, 66.5, 22.5, 16.5)
    ax.text(83.75, 74.75, "视口 0 (slot0) 规格:\n• 色彩格式: RGB565\n• 分辨率: 960 × 540\n• 槽位容量: 1,036,800 B\n• 用途: 左上（第 1 路，UI/视频）",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 72.5, 46.5, 22.5, 17.5)
    ax.text(83.75, 55.25, "视口 1~3 (slot1–3) 规格:\n• 色彩格式: NV12 (YUV420sp)\n• 分辨率: 960 × 540\n• 槽位容量: 777,600 B (各)\n• 用途: 右上/左下/右下（第 2–4 路）",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 72.5, 10.0, 22.5, 34.0, bg_color=COLOR_ORANGE_BG, border_color=COLOR_ORANGE)
    ax.text(83.75, 27.0, "互连带宽与总线占比核算:\n• 原始 RGB888 单路: 46.65 MB/s\n• 4 路并发总带宽: 186.6 MB/s\n• PCIe 链路实测峰值: 861 MB/s\n• 总线带宽占比: 仅 21.7%\n• RGB565 四路负载: 14.5% (124.4 MB/s)\n• NV12 四路负载: 10.8% (93.3 MB/s)\n★ 总线负载极低，多路扩展余量充裕",
            fontproperties=font_bold, size=10.0, color=COLOR_ORANGE, ha="center", va="center")

    return fig


# ---------------------------------------------------------
# 图 3: 启动与模式状态机
# ---------------------------------------------------------
def build_fig3():
    fig, ax = create_base_canvas()
    draw_header(ax, "系统引导启动与多模式交互状态机",
                "从 Linux 上电自启、硬件就绪轮询到实时 ADAS 监控与 U 盘视频回放流转",
                "Fig. 3  启动与模式状态机")

    # 启动阶段节点 (上方横排)
    draw_box(ax, 3.5, 71.0, 16.0, 17.0)
    ax.text(11.5, 79.5, "上电冷启动\n(Power-On)\n────────────\n[屏幕: 待机黑屏]",
            fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 26.5, 71.0, 18.0, 17.0)
    ax.text(35.5, 79.5, "S99adas_menu\n(自启动引导服务)\n────────────\n[屏幕: 控制台终端]",
            fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 52.0, 71.0, 26.0, 17.0)
    ax.text(65.0, 79.5, "run_boot.sh 硬件联调\n(等 0x838=0x20261029)\n────────────\n[屏幕: 蓝色清屏 / 等待固件]",
            fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 启动箭头
    draw_arrow(ax, (19.5, 79.5), (26.5, 79.5), color=COLOR_BORDER, lw=1.6)
    ax.text(23.0, 82.5, "内核引导", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="center", va="bottom")

    draw_arrow(ax, (44.5, 79.5), (52.0, 79.5), color=COLOR_BORDER, lw=1.6)
    ax.text(48.25, 82.5, "脚本调度", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="center", va="bottom")

    # 核心中枢: mode_select
    draw_box(ax, 37.0, 42.0, 26.0, 17.0, bg_color=COLOR_CYAN_BG, border_color=COLOR_CYAN, lw=1.6)
    ax.text(50.0, 50.5, "mode_select\n(模式选择中枢状态)\n────────────\n[屏幕: 双图标界面 (左:实时 / 右:U盘)]",
            fontproperties=font_bold, size=10.5, color=COLOR_CYAN, ha="center", va="center")

    # run_boot.sh -> mode_select 箭头
    draw_arrow(ax, (65.0, 71.0), (53.0, 59.0), color=COLOR_CYAN, lw=1.6)
    ax.text(64.0, 64.0, "版本校验成功", fontproperties=font_bold, size=10.0, color=COLOR_CYAN, ha="center", va="bottom")

    # 左分支: menu_daemon
    draw_box(ax, 3.5, 15.0, 28.0, 20.0)
    ax.text(17.5, 25.0, "menu_daemon (实时 ADAS 监控)\n• 多路摄像头视频流式实时送显\n• rt_lane_det / rt_zebra_det 检测\n• 短按 KEY4: 开启 / 关闭 OSD 弹窗\n────────────\n[屏幕: 四路实时视频 + OSD 告警]",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 右分支: usb_menu
    draw_box(ax, 68.5, 15.0, 28.0, 20.0)
    ax.text(82.5, 25.0, "usb_menu (U盘视频回放)\n• 扫描检索外部 U 盘 MP4 列表\n• KEY0 移动光标 / KEY1 选定视频\n• 四路硬解并发回放与状态控制\n────────────\n[屏幕: 文件管理列表 / 并发播放]",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 下方: 退出状态
    draw_box(ax, 38.0, 15.0, 24.0, 14.0, bg_color=COLOR_ORANGE_BG, border_color=COLOR_ORANGE, lw=1.4)
    ax.text(50.0, 22.0, "系统退出 (Exit)\n释放 PCIe 并关闭进程\n────────────\n[屏幕: 恢复 Linux 终端命令行]",
            fontproperties=font_bold, size=10.0, color=COLOR_ORANGE, ha="center", va="center")

    # mode_select <-> menu_daemon 交互箭头
    draw_arrow(ax, (39.0, 48.0), (22.0, 35.0), color=COLOR_CYAN, lw=1.6)
    ax.text(28.0, 43.5, "-- KEY1 (左) -->", fontproperties=font_bold, size=10.0, color=COLOR_CYAN, ha="center", va="bottom")

    draw_arrow(ax, (26.0, 35.0), (43.0, 42.0), color=COLOR_ORANGE, lw=1.4, ls="--")
    ax.text(32.0, 36.5, "<-- 长按 KEY4 --", fontproperties=font_bold, size=10.0, color=COLOR_ORANGE, ha="center", va="top")

    # mode_select <-> usb_menu 交互箭头
    draw_arrow(ax, (61.0, 48.0), (78.0, 35.0), color=COLOR_CYAN, lw=1.6)
    ax.text(72.0, 43.5, "-- KEY1 (右) -->", fontproperties=font_bold, size=10.0, color=COLOR_CYAN, ha="center", va="bottom")

    draw_arrow(ax, (74.0, 35.0), (57.0, 42.0), color=COLOR_ORANGE, lw=1.4, ls="--")
    ax.text(68.0, 36.5, "-- 长按 KEY4 -->", fontproperties=font_bold, size=10.0, color=COLOR_ORANGE, ha="center", va="top")

    # mode_select -> 退出 箭头
    draw_arrow(ax, (50.0, 42.0), (50.0, 29.0), color=COLOR_ORANGE, lw=1.6)
    ax.text(52.5, 34.5, "-- KEY4 长按 -->", fontproperties=font_bold, size=10.0, color=COLOR_ORANGE, ha="left", va="center")

    # 底部说明条
    draw_box(ax, 3.5, 4.0, 93.0, 7.5, bg_color=COLOR_CARD_BG, border_color=COLOR_BORDER)
    ax.text(50.0, 7.75, "交互操作规范: mode_select 界面短按 KEY0 切换左右高亮光标，短按 KEY1 进入选定模式；\n在实时 ADAS 与 U 盘模式下长按 KEY4 回到 mode_select；在选择中枢状态长按 KEY4 退出程序。",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="center", va="center")

    return fig


# ---------------------------------------------------------
# 图 4: 四宫格帧存布局
# ---------------------------------------------------------
def build_fig4():
    fig, ax = create_base_canvas()
    draw_header(ax, "FPGA 片上 DDR3 四宫格帧存物理布局与寄存器配置",
                "基地址: 0x04000000 | 槽间距: 0x00400000 (4 MB) | 独立 Commit 异步帧同步",
                "Fig. 4  四宫格帧存布局")

    # 左侧大框: 四宫格视口排布
    draw_box(ax, 3.5, 6.5, 61.0, 84.0, bg_color=COLOR_CONTAINER_BG, border_color=COLOR_BORDER, lw=1.4)
    ax.text(34.0, 87.0, "1080P 显示屏对应四宫格视口排布 (1920 × 1080 @ 60Hz)",
            fontproperties=font_bold, size=11.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # slot0 (左上)
    draw_box(ax, 5.5, 48.0, 27.5, 36.0, bg_color=COLOR_CYAN_BG, border_color=COLOR_CYAN, lw=1.5)
    ax.text(19.25, 66.0, "视口 0 (slot0) - 左上（第 1 路）\n基址: 0x04000000\n像素格式: RGB565 (16 bpp)\n分辨率: 960 × 540\n占用空间: 1036800 字节\n(960 × 540 × 2 B)\n独立读取器: rt_disp_win_reader_rgb",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # slot1 (右上)
    draw_box(ax, 35.0, 48.0, 27.5, 36.0)
    ax.text(48.75, 66.0, "视口 1 (slot1) - 右上（第 2 路）\n基址: 0x04400000\n像素格式: NV12 (YUV420sp)\n分辨率: 960 × 540\n占用空间: 777600 字节\n(Y: 518400 B + UV: 259200 B)\n独立读取器: rt_disp_win_reader",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # slot2 (左下)
    draw_box(ax, 5.5, 9.5, 27.5, 36.0)
    ax.text(19.25, 27.5, "视口 2 (slot2) - 左下（第 3 路）\n基址: 0x04800000\n像素格式: NV12 (YUV420sp)\n分辨率: 960 × 540\n占用空间: 777600 字节\n(Y: 518400 B + UV: 259200 B)\n独立读取器: rt_disp_win_reader",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # slot3 (右下)
    draw_box(ax, 35.0, 9.5, 27.5, 36.0)
    ax.text(48.75, 27.5, "视口 3 (slot3) - 右下（第 4 路）\n基址: 0x04C00000\n像素格式: NV12 (YUV420sp)\n分辨率: 960 × 540\n占用空间: 777600 字节\n(Y: 518400 B + UV: 259200 B)\n独立读取器: rt_disp_win_reader",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 右侧框: 寄存器与参数说明
    draw_box(ax, 66.5, 6.5, 30.0, 84.0, bg_color=COLOR_CONTAINER_BG, border_color=COLOR_CYAN, lw=1.5)
    ax.text(81.5, 87.0, "控制寄存器与参数配置 (BAR1 MMIO)",
            fontproperties=font_bold, size=11.5, color=COLOR_CYAN, ha="center", va="center")

    draw_box(ax, 68.5, 68.0, 26.0, 15.0)
    ax.text(81.5, 75.5, "寄存器 0x80C = 960 (STRIDE 跨度)\n说明: 图像行跨度寄存器，配置为 960。\n硬件视频读取器按此步长换行读取光栅像素。",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 68.5, 50.0, 26.0, 15.0)
    ax.text(81.5, 57.5, "寄存器 0x810 = 518400 (UV_OFFSET)\n说明: NV12 色度相对亮度起始地址偏移量。\n对应 960 × 540 亮度平面字节数 (518400 B)。",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 68.5, 32.0, 26.0, 15.0)
    ax.text(81.5, 39.5, "寄存器 0x814 (COMMIT 提交)\n说明: 写入格式 (fid << 16) | slot。\n触发硬件在下一个垂直消隐期 (V-Blank)\n原子倒换读写指针，彻底消除画面撕裂。",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 68.5, 9.5, 26.0, 19.5, bg_color=COLOR_CYAN_BG, border_color=COLOR_CYAN)
    ax.text(81.5, 19.25, "显存地址分配参数总结:\n• DDR3 帧存起始基址: 0x04000000\n• 槽间距 (Pitch): 0x00400000 (4 MB 对齐)\n• slot0 容量: 1036800 B (RGB565)\n• slot1~3 容量: 777600 B (NV12)\n• 独立 Shadow 锁存，各路刷新率解耦",
            fontproperties=font_bold, size=10.0, color=COLOR_CYAN, ha="center", va="center")

    return fig


# ---------------------------------------------------------
# 图 5: 按键映射表 (图形式)
# ---------------------------------------------------------
def build_fig5():
    fig, ax = create_base_canvas()
    draw_header(ax, "五向实体按键多级事件响应矩阵与 FPGA 动作映射",
                "硬件消抖、多级持续时间判定 (0x844) 与双业务复用规范",
                "Fig. 5  按键映射表（图形式）")

    # 表格列范围:
    # Col 0 (按键定义): 3.5 ~ 22.5 (w=19)
    # Col 1 (短按): 24.5 ~ 47.5 (w=23)
    # Col 2 (长按): 49.5 ~ 72.5 (w=23)
    # Col 3 (按住 3s): 74.5 ~ 96.5 (w=22)

    # 表头
    draw_box(ax, 3.5, 83.5, 19.0, 6.0, bg_color=COLOR_CARD_BG, border_color=COLOR_BORDER)
    ax.text(13.0, 86.5, "实体按键 (硬件引脚)", fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 24.5, 83.5, 23.0, 6.0, bg_color=COLOR_CARD_BG, border_color=COLOR_BORDER)
    ax.text(36.0, 86.5, "短按事件 (Short < 1s)", fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 49.5, 83.5, 23.0, 6.0, bg_color=COLOR_CARD_BG, border_color=COLOR_BORDER)
    ax.text(61.0, 86.5, "长按事件 (Long 1~3s)", fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 74.5, 83.5, 22.0, 6.0, bg_color=COLOR_CARD_BG, border_color=COLOR_BORDER)
    ax.text(85.5, 86.5, "按住 3s 事件 (Hold ≥ 3s)", fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # Row 1: KEY0
    draw_box(ax, 3.5, 72.5, 19.0, 9.5)
    ax.text(13.0, 77.25, "KEY0 (引脚 C22)", fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 24.5, 72.5, 23.0, 9.5)
    ax.text(36.0, 77.25, "自车车道循环切换 (lane: 0→1→2)\n[菜单模式: 光标移动 / 下一项]", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 49.5, 72.5, 23.0, 9.5)
    ax.text(61.0, 77.25, "无动作 (保持当前车道状态)", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="center", va="center")
    draw_box(ax, 74.5, 72.5, 22.0, 9.5)
    ax.text(85.5, 77.25, "无动作", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="center", va="center")

    # Row 2: KEY1
    draw_box(ax, 3.5, 61.5, 19.0, 9.5)
    ax.text(13.0, 66.25, "KEY1 (引脚 C23)", fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 24.5, 61.5, 23.0, 9.5)
    ax.text(36.0, 66.25, "行驶 / 停车切换 (moving = ~moving)\n[菜单模式: 确认选择 / 进入]", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 49.5, 61.5, 23.0, 9.5)
    ax.text(61.0, 66.25, "无动作 (保持当前行驶状态)", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="center", va="center")
    draw_box(ax, 74.5, 61.5, 22.0, 9.5)
    ax.text(85.5, 66.25, "无动作", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="center", va="center")

    # Row 3: KEY2
    draw_box(ax, 3.5, 50.5, 19.0, 9.5)
    ax.text(13.0, 55.25, "KEY2 (引脚 B22)", fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 24.5, 50.5, 23.0, 9.5)
    ax.text(36.0, 55.25, "左转向变道请求 (left_req=1, force=0)\n触发车道线合规判定 (虚线通行/实线违规)", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 49.5, 50.5, 23.0, 9.5, bg_color=COLOR_ORANGE_BG, border_color=COLOR_ORANGE)
    ax.text(61.0, 55.25, "强制左变道压线 (left_req=1, force=1)\n强制触发变道告警与红框闪烁", fontproperties=font_bold, size=10.0, color=COLOR_ORANGE, ha="center", va="center")
    draw_box(ax, 74.5, 50.5, 22.0, 9.5)
    ax.text(85.5, 55.25, "无动作", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="center", va="center")

    # Row 4: KEY3
    draw_box(ax, 3.5, 39.5, 19.0, 9.5)
    ax.text(13.0, 44.25, "KEY3 (引脚 A22)", fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 24.5, 39.5, 23.0, 9.5)
    ax.text(36.0, 44.25, "右转向变道请求 (right_req=1, force=0)\n触发车道线合规判定 (虚线通行/实线违规)", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 49.5, 39.5, 23.0, 9.5, bg_color=COLOR_ORANGE_BG, border_color=COLOR_ORANGE)
    ax.text(61.0, 44.25, "强制右变道压线 (right_req=1, force=1)\n强制触发变道告警与红框闪烁", fontproperties=font_bold, size=10.0, color=COLOR_ORANGE, ha="center", va="center")
    draw_box(ax, 74.5, 39.5, 22.0, 9.5)
    ax.text(85.5, 44.25, "无动作", fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MUTED, ha="center", va="center")

    # Row 5: KEY4
    draw_box(ax, 3.5, 28.5, 19.0, 9.5)
    ax.text(13.0, 33.25, "KEY4 (引脚 B20)", fontproperties=font_bold, size=10.5, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 24.5, 28.5, 23.0, 9.5)
    ax.text(36.0, 33.25, "FPGA：disp_mode 取反（仅状态回读）\n菜单软件：开关 OSD 配置弹窗", fontproperties=font_reg, size=9.5, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 49.5, 28.5, 23.0, 9.5)
    ax.text(61.0, 33.25, "FPGA：src_sel 取反（仅状态回读）\n菜单软件：长按 1–2 s 退出到选择界面", fontproperties=font_reg, size=9.5, color=COLOR_TEXT_MAIN, ha="center", va="center")
    draw_box(ax, 74.5, 28.5, 22.0, 9.5, bg_color=COLOR_ORANGE_BG, border_color=COLOR_ORANGE)
    ax.text(85.5, 33.25, "★ 触发 BEV 透视标定模式\n(cal_mode = 1，投射标定十字准星)", fontproperties=font_bold, size=10.0, color=COLOR_ORANGE, ha="center", va="center")

    # 底部说明与约束卡片 (两栏并排)
    draw_box(ax, 3.5, 6.5, 45.0, 19.5, bg_color=COLOR_ORANGE_BG, border_color=COLOR_ORANGE, lw=1.3)
    ax.text(26.0, 16.25, "【规范】菜单交互基线约束规范:\n\"菜单占用 KEY0/KEY1，故 ADAS 需按键基线\"\nUI 菜单复用 KEY0 作为移动、KEY1 作为确认。系统启动及模式切换退出时，\n必须读取 BAR1 0x844 序号作为基线 (last_seq)，丢弃菜单期间残留的按键事件，\n防止进入实时 ADAS 后因按键积压引发车道误切换或启停突变。",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 51.5, 6.5, 45.0, 19.5, bg_color=COLOR_ORANGE_BG, border_color=COLOR_ORANGE, lw=1.3)
    ax.text(74.0, 16.25, "【规范】标定模式防误触要求 (现场演示时序规范):\n\"KEY4 按住 3 s 会进 cal_mode，演示须在 3 s 内松开\"\nKEY4 持续按住超过 3 秒将置位硬件 cal_mode 进入标定模式并锁定画面；\n答辩或现场演示“长按返回”时，按键须在 1~2 秒内松开，严禁按住超过 3 秒，\n以确保系统平滑返回 mode_select 而不误触发透视标定准星。",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    return fig


# ---------------------------------------------------------
# 图 6: FPGA 片内模块划分
# ---------------------------------------------------------
def build_fig6():
    fig, ax = create_base_canvas()
    draw_header(ax, "紫光同创 PG2L100H FPGA 片内硬件模块架构与资源分布",
                "全流式纳秒级机器视觉中枢与四路视频无撕裂集线引擎架构",
                "Fig. 6  FPGA 片内模块划分")

    # 顶层容器: pango_pcie_dma_top
    draw_box(ax, 3.5, 25.5, 93.0, 64.5, bg_color=COLOR_CONTAINER_BG, border_color=COLOR_CYAN, lw=1.5)
    ax.text(50.0, 87.0, "顶层模块: pango_pcie_dma_top",
            fontproperties=font_bold, size=12.0, color=COLOR_CYAN, ha="center", va="center")

    # 左侧大子模块: rt_disp_top
    draw_box(ax, 5.5, 27.5, 49.5, 56.5, bg_color=COLOR_CARD_BG, border_color=COLOR_BORDER, lw=1.2)
    ax.text(30.25, 81.0, "显示与集线顶层模块: rt_disp_top",
            fontproperties=font_bold, size=11.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # rt_disp_top 内部 6 个子模块 (2 列 × 3 排)
    # 排 1
    draw_box(ax, 7.5, 63.5, 22.0, 14.5)
    ax.text(18.5, 70.75, "rt_ddr_rd_arb\n多通道 DDR3 读仲裁器\n(四通道轮询 Round-Robin)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 31.0, 63.5, 22.0, 14.5)
    ax.text(42.0, 70.75, "rt_disp_win_reader\n四视口窗口流读取器\n(NV12 / RGB565 解调)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 排 2
    draw_box(ax, 7.5, 46.5, 22.0, 14.5)
    ax.text(18.5, 53.75, "rt_osd\n多图层矢量/光栅 OSD 引擎\n(16组目标框 / 箭头 / 状态字符)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 31.0, 46.5, 22.0, 14.5)
    ax.text(42.0, 53.75, "rt_osd_ctl\nOSD 状态机与按键分发\n(事件解析与 BEV 标定控制)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 排 3
    draw_box(ax, 7.5, 29.5, 22.0, 14.5)
    ax.text(18.5, 36.75, "rt_ext_regs\n扩展控制寄存器池\n(BAR1 0x800~0x900 MMIO)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 31.0, 29.5, 22.0, 14.5)
    ax.text(42.0, 36.75, "rt_keys\n5向实体按键消抖与编码\n(时序计数与多级事件生成)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 右侧子模块 (从上到下 4 个)
    draw_box(ax, 57.5, 69.5, 37.0, 14.5)
    ax.text(76.0, 76.75, "PCIe 端点控制器 (PCIe Endpoint)\nPCIe Gen2 x2 IP 协议栈 & 门铃 Scatter-Gather DMA Master",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 57.5, 56.0, 37.0, 12.0)
    ax.text(76.0, 62.0, "DDR3 控制器硬核 (DDR3 Memory Controller)\n32-bit 总线 @ 400 MHz (800 Mbps)，提供 >25.6 Gbps 吞吐带宽",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 57.5, 42.5, 37.0, 12.0)
    ax.text(76.0, 48.5, "rt_lane_det (流式车道线检测核)\n单遍光栅单扫描流水线，累加器最小二乘定点拟合斜率与截距",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 57.5, 29.0, 37.0, 12.0)
    ax.text(76.0, 35.0, "rt_zebra_det (流式斑马线检测核)\n垂直与水平梯度边缘投影统计，周期性斑马线条纹硬件判决",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    # 底部片上资源仪表盘
    draw_box(ax, 3.5, 5.5, 93.0, 17.5, bg_color=COLOR_CARD_BG, border_color=COLOR_CYAN, lw=1.3)
    ax.text(50.0, 20.0, "紫光同创盘古 100Pro+ (PG2L100H) 片上硬件资源占用指标 (cam11 固件基线)",
            fontproperties=font_bold, size=10.5, color=COLOR_CYAN, ha="center", va="center")

    # 4 个资源卡片
    draw_box(ax, 5.5, 7.5, 21.0, 10.0, bg_color=COLOR_CONTAINER_BG, border_color=COLOR_BORDER)
    ax.text(16.0, 12.5, "LUT 查找表: 40.0%\n26,645 / 66,600 (余量充裕)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 28.5, 7.5, 21.0, 10.0, bg_color=COLOR_CONTAINER_BG, border_color=COLOR_BORDER)
    ax.text(39.0, 12.5, "FF 触发器: 19.3%\n25,730 / 133,200 (时序极稳)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 51.5, 7.5, 21.0, 10.0, bg_color=COLOR_CONTAINER_BG, border_color=COLOR_BORDER)
    ax.text(62.0, 12.5, "DRM 块存储: 63.8%\n99 / 155 (行缓冲与字模)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    draw_box(ax, 74.5, 7.5, 20.0, 10.0, bg_color=COLOR_CONTAINER_BG, border_color=COLOR_BORDER)
    ax.text(84.5, 12.5, "APM 乘加器: 25.4%\n61 / 240 (拟合与除法算子)",
            fontproperties=font_reg, size=10.0, color=COLOR_TEXT_MAIN, ha="center", va="center")

    return fig


# ---------------------------------------------------------
# 主流程
# ---------------------------------------------------------
def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    figures = [
        ("fig1", "fig1_system.png", build_fig1),
        ("fig2", "fig2_dataflow.png", build_fig2),
        ("fig3", "fig3_boot.png", build_fig3),
        ("fig4", "fig4_fbmap.png", build_fig4),
        ("fig5", "fig5_keys.png", build_fig5),
        ("fig6", "fig6_fpga.png", build_fig6),
    ]

    for name, filename, builder in figures:
        fig = builder()
        check_bboxes(fig, name)

        out_path = os.path.join(OUTPUT_DIR, filename)
        fig.savefig(out_path, dpi=DPI, facecolor=COLOR_BG)
        plt.close(fig)

        # 用 PIL 读回并校验规格
        with Image.open(out_path) as img:
            w, h = img.size
            size_kb = os.path.getsize(out_path) / 1024.0
            print(f"[{name}] {filename}: {w}×{h} px, {size_kb:.1f} KB")

            if w < 3000:
                print(f"FAIL {name}: width {w} < 3000 px")
                sys.exit(1)
            if size_kb < 60.0:
                print(f"FAIL {name}: file size {size_kb:.1f} KB < 60 KB")
                sys.exit(1)

    print("All 6 figures generated and validated successfully.")


if __name__ == "__main__":
    main()
