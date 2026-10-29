#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_selector.py
ADAS 演示机 - 开机二选一界面素材生成工具
生成 1920x1080 全屏二选一素材，并裁切导出四个象限：
- sel0.rgb565 (左上 960x540, RGB565 小端, 1,036,800 B)
- sel1.nv12   (右上 960x540, NV12 BT.601 limited, 777,600 B)
- sel2.nv12   (左下 960x540, NV12 BT.601 limited, 777,600 B)
- sel3.nv12   (右下 960x540, NV12 BT.601 limited, 777,600 B)
- sel_preview.png (1920x1080 预览图)
"""

import os
import sys
import hashlib
import numpy as np
from PIL import Image, ImageDraw, ImageFont

FULL_WIDTH = 1920
FULL_HEIGHT = 1080
QUAD_WIDTH = 960
QUAD_HEIGHT = 540

BG_COLOR = "#0E1620"          # 深色底 (14, 22, 32)
CARD_BG = "#131B27"           # 卡片微亮底色 (19, 27, 39)
CARD_BORDER = "#1E293B"       # 卡片边框 (30, 41, 59)
DIVIDER_COLOR = "#2A374A"     # 中央分隔线 (42, 55, 74)
CYAN_COLOR = "#22D3EE"        # 青色强调 (34, 211, 238)
TITLE_COLOR = "#FFFFFF"       # 白色主标题
SUBTITLE_COLOR = "#94A3B8"    # 灰色副标题 (148, 163, 184)
FOOTER_KEY_COLOR = "#22D3EE"  # 按键青色
FOOTER_TXT_COLOR = "#94A3B8"  # 按键说明灰

FONT_BOLD_PATH = "C:/Windows/Fonts/msyhbd.ttc"
FONT_REGULAR_PATH = "C:/Windows/Fonts/msyh.ttc"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "menu")


def rgb_to_rgb565(rgb_array):
    """转换为 RGB565 小端 (uint16)"""
    r = rgb_array[..., 0].astype(np.uint16)
    g = rgb_array[..., 1].astype(np.uint16)
    b = rgb_array[..., 2].astype(np.uint16)
    val = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    return val.astype("<u2").tobytes(), val


def decode_rgb565(val_u16):
    """解码 RGB565 到 RGB888 (中点还原保证最大量化误差 <= 4)"""
    r5 = (val_u16 >> 11) & 0x1F
    g6 = (val_u16 >> 5) & 0x3F
    b5 = val_u16 & 0x1F
    r = (r5 << 3) + 3
    g = (g6 << 2) + 1
    b = (b5 << 3) + 3
    return np.array([r, g, b], dtype=np.uint8)


def rgb_to_nv12(rgb_array):
    """
    转换为 NV12 (BT.601 limited range)
    Y: [16, 235], U/V: [16, 240]
    """
    h, w, _ = rgb_array.shape
    r = rgb_array[..., 0].astype(np.float32)
    g = rgb_array[..., 1].astype(np.float32)
    b = rgb_array[..., 2].astype(np.float32)

    y = 16.0 + (65.481 * r + 128.553 * g + 24.966 * b) / 255.0
    u = 128.0 + (-37.797 * r - 74.203 * g + 112.000 * b) / 255.0
    v = 128.0 + (112.000 * r - 93.786 * g - 18.214 * b) / 255.0

    y_plane = np.clip(np.round(y), 16, 235).astype(np.uint8)
    u_clip = np.clip(np.round(u), 16, 240)
    v_clip = np.clip(np.round(v), 16, 240)

    u_sub = (
        u_clip[0::2, 0::2]
        + u_clip[0::2, 1::2]
        + u_clip[1::2, 0::2]
        + u_clip[1::2, 1::2]
    ) / 4.0
    v_sub = (
        v_clip[0::2, 0::2]
        + v_clip[0::2, 1::2]
        + v_clip[1::2, 0::2]
        + v_clip[1::2, 1::2]
    ) / 4.0

    h_uv = h // 2
    uv_plane = np.empty((h_uv, w), dtype=np.uint8)
    uv_plane[:, 0::2] = np.clip(np.round(u_sub), 16, 240).astype(np.uint8)
    uv_plane[:, 1::2] = np.clip(np.round(v_sub), 16, 240).astype(np.uint8)

    raw_bytes = y_plane.tobytes() + uv_plane.tobytes()
    return raw_bytes, y_plane, uv_plane


def decode_nv12_pixel(y_plane, uv_plane, py, px):
    """解码 NV12 单个像素回到 RGB888"""
    y_val = float(y_plane[py, px]) - 16.0
    u_val = float(uv_plane[py // 2, (px // 2) * 2]) - 128.0
    v_val = float(uv_plane[py // 2, (px // 2) * 2 + 1]) - 128.0

    c_y = 255.0 / 219.0
    r = np.clip(np.round(c_y * y_val + 1.59602679 * v_val), 0, 255)
    g = np.clip(np.round(c_y * y_val - 0.39176229 * u_val - 0.81296765 * v_val), 0, 255)
    b = np.clip(np.round(c_y * y_val + 2.01723214 * u_val), 0, 255)
    return np.array([r, g, b], dtype=np.uint8)


def get_file_md5(filepath):
    hasher = hashlib.md5()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()


def render_full_screen():
    """绘制完整的 1920x1080 二选一界面"""
    img = Image.new("RGB", (FULL_WIDTH, FULL_HEIGHT), BG_COLOR)
    draw = ImageDraw.Draw(img)

    font_title = ImageFont.truetype(FONT_BOLD_PATH, 80)
    font_sub = ImageFont.truetype(FONT_REGULAR_PATH, 32)
    font_bot = ImageFont.truetype(FONT_REGULAR_PATH, 24)
    font_badge = ImageFont.truetype(FONT_BOLD_PATH, 22)

    # 1. 左右卡片内衬背景 (留出外围黄色高亮框的空间，高亮在 8..951 与 968..1911)
    card_margin_x = 40
    card_margin_y = 48
    card_w = 960 - 2 * card_margin_x
    card_h = 1080 - 2 * card_margin_y - 60  # 底部留空间给说明文字

    # 左卡内衬
    lx0 = card_margin_x
    ly0 = card_margin_y
    lx1 = 960 - card_margin_x
    ly1 = ly0 + card_h
    draw.rectangle([lx0, ly0, lx1, ly1], fill=CARD_BG, outline=CARD_BORDER, width=2)

    # 右卡内衬
    rx0 = 960 + card_margin_x
    ry0 = card_margin_y
    rx1 = 1920 - card_margin_x
    ry1 = ry0 + card_h
    draw.rectangle([rx0, ry0, rx1, ry1], fill=CARD_BG, outline=CARD_BORDER, width=2)

    # 2. 中央分隔线
    div_x = 960
    draw.line([(div_x, 60), (div_x, 960)], fill=DIVIDER_COLOR, width=2)

    # 3. 左半部分内容 (中心 x = 480)
    # 青色强调装饰条
    draw.rectangle([480 - 60, 200, 480 + 60, 206], fill=CYAN_COLOR)

    # 模式标号
    badge_left = "MODE 01"
    b_bb = draw.textbbox((0, 0), badge_left, font=font_badge)
    b_w = b_bb[2] - b_bb[0]
    draw.text((480 - b_w // 2, 228), badge_left, font=font_badge, fill=CYAN_COLOR)

    # 标题:「四路摄像头」 80px
    t_left = "四路摄像头"
    t_bb = draw.textbbox((0, 0), t_left, font=font_title)
    t_w = t_bb[2] - t_bb[0]
    draw.text((480 - t_w // 2, 330), t_left, font=font_title, fill=TITLE_COLOR)

    # 副标题:「3×USB + 1×FPGA 实时画面」 32px
    s_left = "3×USB + 1×FPGA 实时画面"
    s_bb = draw.textbbox((0, 0), s_left, font=font_sub)
    s_w = s_bb[2] - s_bb[0]
    draw.text((480 - s_w // 2, 455), s_left, font=font_sub, fill=SUBTITLE_COLOR)

    # 4. 右半部分内容 (中心 x = 1440)
    # 青色强调装饰条
    draw.rectangle([1440 - 60, 200, 1440 + 60, 206], fill=CYAN_COLOR)

    # 模式标号
    badge_right = "MODE 02"
    b_bb = draw.textbbox((0, 0), badge_right, font=font_badge)
    b_w = b_bb[2] - b_bb[0]
    draw.text((1440 - b_w // 2, 228), badge_right, font=font_badge, fill=CYAN_COLOR)

    # 标题:「U盘视频流」 80px
    t_right = "U盘视频流"
    t_bb = draw.textbbox((0, 0), t_right, font=font_title)
    t_w = t_bb[2] - t_bb[0]
    draw.text((1440 - t_w // 2, 330), t_right, font=font_title, fill=TITLE_COLOR)

    # 副标题:「选择 1~4 个视频分屏播放」 32px
    s_right = "选择 1~4 个视频分屏播放"
    s_bb = draw.textbbox((0, 0), s_right, font=font_sub)
    s_w = s_bb[2] - s_bb[0]
    draw.text((1440 - s_w // 2, 455), s_right, font=font_sub, fill=SUBTITLE_COLOR)

    # 5. 下半部分各卡片特性说明 (y > 540)
    # 左卡特性标签
    left_tags = ["4路实时输入", "低延迟显示", "ADAS 算法联动"]
    tag_y = 660
    for i, tag in enumerate(left_tags):
        tag_bb = draw.textbbox((0, 0), tag, font=font_sub)
        tw = tag_bb[2] - tag_bb[0]
        tx = 480 - tw // 2
        ty = tag_y + i * 65
        # 小圆点装饰
        draw.ellipse([tx - 24, ty + 10, tx - 14, ty + 20], fill=CYAN_COLOR)
        draw.text((tx, ty), tag, font=font_sub, fill=SUBTITLE_COLOR)

    # 右卡特性标签
    right_tags = ["U盘即插即读", "1~4 路视频自适应", "多格式流畅回放"]
    for i, tag in enumerate(right_tags):
        tag_bb = draw.textbbox((0, 0), tag, font=font_sub)
        tw = tag_bb[2] - tag_bb[0]
        tx = 1440 - tw // 2
        ty = tag_y + i * 65
        # 小圆点装饰
        draw.ellipse([tx - 24, ty + 10, tx - 14, ty + 20], fill=CYAN_COLOR)
        draw.text((tx, ty), tag, font=font_sub, fill=SUBTITLE_COLOR)

    # 6. 底部小字「KEY0 切换    KEY1 进入」 24px，居中
    # 计算各段宽度
    seg1 = "KEY0"
    seg2 = " 切换       "
    seg3 = "KEY1"
    seg4 = " 进入"

    w1 = draw.textbbox((0, 0), seg1, font=font_bot)[2] - draw.textbbox((0, 0), seg1, font=font_bot)[0]
    w2 = draw.textbbox((0, 0), seg2, font=font_bot)[2] - draw.textbbox((0, 0), seg2, font=font_bot)[0]
    w3 = draw.textbbox((0, 0), seg3, font=font_bot)[2] - draw.textbbox((0, 0), seg3, font=font_bot)[0]
    w4 = draw.textbbox((0, 0), seg4, font=font_bot)[2] - draw.textbbox((0, 0), seg4, font=font_bot)[0]
    total_w = w1 + w2 + w3 + w4
    start_x = 960 - total_w // 2
    bot_y = 1015

    draw.text((start_x, bot_y), seg1, font=font_bot, fill=FOOTER_KEY_COLOR)
    draw.text((start_x + w1, bot_y), seg2, font=font_bot, fill=FOOTER_TXT_COLOR)
    draw.text((start_x + w1 + w2, bot_y), seg3, font=font_bot, fill=FOOTER_KEY_COLOR)
    draw.text((start_x + w1 + w2 + w3, bot_y), seg4, font=font_bot, fill=FOOTER_TXT_COLOR)

    return img


def main():
    print("=" * 60)
    print("ADAS 演示机 - 开机二选一界面素材生成")
    print(f"输出目录: {OUTPUT_DIR}")
    print("=" * 60)

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # 1. 渲染整屏图像 (1920x1080)
    full_img = render_full_screen()

    # 保存预览图
    preview_path = os.path.join(OUTPUT_DIR, "sel_preview.png")
    full_img.save(preview_path, format="PNG")
    print(f"预览图已保存: {preview_path}")

    # 2. 裁切为 4 个象限
    # slot0: (0, 0, 960, 540)       -> 左上 (RGB565)
    # slot1: (960, 0, 1920, 540)     -> 右上 (NV12)
    # slot2: (0, 540, 960, 1080)     -> 左下 (NV12)
    # slot3: (960, 540, 1920, 1080)   -> 右下 (NV12)
    quad_boxes = [
        (0, 0, QUAD_WIDTH, QUAD_HEIGHT),
        (QUAD_WIDTH, 0, FULL_WIDTH, QUAD_HEIGHT),
        (0, QUAD_HEIGHT, QUAD_WIDTH, FULL_HEIGHT),
        (QUAD_WIDTH, QUAD_HEIGHT, FULL_WIDTH, FULL_HEIGHT),
    ]

    quad_imgs = [full_img.crop(box) for box in quad_boxes]

    # 3. 导出 sel0.rgb565, sel1.nv12, sel2.nv12, sel3.nv12
    # sel0 (RGB565)
    arr0 = np.array(quad_imgs[0])
    sel0_bytes, sel0_u16 = rgb_to_rgb565(arr0)
    sel0_path = os.path.join(OUTPUT_DIR, "sel0.rgb565")
    with open(sel0_path, "wb") as f:
        f.write(sel0_bytes)

    # sel1..3 (NV12)
    nv12_data = []
    for i in range(1, 4):
        arr = np.array(quad_imgs[i])
        raw_nv12, y_p, uv_p = rgb_to_nv12(arr)
        sel_path = os.path.join(OUTPUT_DIR, f"sel{i}.nv12")
        with open(sel_path, "wb") as f:
            f.write(raw_nv12)
        nv12_data.append((y_p, uv_p))

    # 4. 打印每文件大小与 MD5
    file_specs = [
        ("sel0.rgb565", 1036800),
        ("sel1.nv12", 777600),
        ("sel2.nv12", 777600),
        ("sel3.nv12", 777600),
        ("sel_preview.png", None),
    ]

    print("\n[生成文件清单、尺寸与 MD5 校验]:")
    all_ok = True
    for fname, exp_sz in file_specs:
        fpath = os.path.join(OUTPUT_DIR, fname)
        if not os.path.exists(fpath):
            print(f"  [MISSING] {fname}")
            all_ok = False
            continue
        sz = os.path.getsize(fpath)
        md5_v = get_file_md5(fpath)
        if exp_sz is not None and sz != exp_sz:
            print(f"  [FAIL] {fname}: 实际={sz}, 期望={exp_sz}")
            all_ok = False
        else:
            print(f"  [OK]   {fname:<16} 大小={sz:>10} 字节 | MD5={md5_v}")

    if not all_ok:
        print("[ERROR] 文件大小或生成异常!")
        sys.exit(1)

    # 5. 抽样像素量化误差比对 (容许误差 <= 4)
    print("\n[抽样像素量化误差比对 (容许误差 <= 4)]:")
    max_err_all = 0

    # 象限 0 (sel0, RGB565)
    w_pts0 = np.argwhere((arr0[..., 0] == 255) & (arr0[..., 1] == 255) & (arr0[..., 2] == 255))
    w_y0, w_x0 = w_pts0[len(w_pts0) // 2]
    samples_q0 = [
        (50, 50, "背景区"),
        (203, 480, "青色装饰条"),
        (int(w_y0), int(w_x0), "白色主标题"),
    ]
    for py, px, desc in samples_q0:
        orig = arr0[py, px]
        dec = decode_rgb565(sel0_u16[py, px])
        err = int(np.max(np.abs(orig.astype(int) - dec.astype(int))))
        max_err_all = max(max_err_all, err)
        print(f"  象限0 (RGB565) 点({px:>3},{py:>3}) [{desc}]: 原图={orig} 解码={dec} 误差={err}")

    # 象限 1..3 (NV12)
    for q_idx in range(1, 4):
        arr_q = np.array(quad_imgs[q_idx])
        y_p, uv_p = nv12_data[q_idx - 1]
        if q_idx == 1:
            w_pts1 = np.argwhere((arr_q[..., 0] == 255) & (arr_q[..., 1] == 255) & (arr_q[..., 2] == 255))
            w_y1, w_x1 = w_pts1[len(w_pts1) // 2]
            samples = [
                (50, 50, "背景区"),
                (203, 480, "青色装饰条"),
                (int(w_y1), int(w_x1), "白色主标题"),
            ]
        elif q_idx == 2:
            samples = [
                (50, 50, "背景区"),
                (120, 480, "特性文字"),
            ]
        else:
            samples = [
                (50, 50, "背景区"),
                (120, 480, "特性文字"),
            ]

        for py, px, desc in samples:
            orig = arr_q[py, px]
            dec = decode_nv12_pixel(y_p, uv_p, py, px)
            err = int(np.max(np.abs(orig.astype(int) - dec.astype(int))))
            max_err_all = max(max_err_all, err)
            print(f"  象限{q_idx} (NV12)   点({px:>3},{py:>3}) [{desc}]: 原图={orig} 解码={dec} 误差={err}")

    print(f"\n抽样像素最大误差: {max_err_all} (约束 <= 4)")
    if max_err_all > 4:
        print("[ERROR] 抽样像素误差超出阈值!")
        sys.exit(2)

    print("[SUCCESS] 素材生成成功，退出码 0")
    sys.exit(0)


if __name__ == "__main__":
    main()
