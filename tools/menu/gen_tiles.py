#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_tiles.py
2026 嵌赛 ADAS 演示 - 启动界面四分屏菜单卡片生成工具
生成 4 张 960x540 静态卡片，并导出为:
- RGB565 小端二进制文件 (tile0.rgb565 ~ tile3.rgb565)
- NV12 BT.601 limited range 二进制文件 (tile0.nv12 ~ tile3.nv12)
- 2x2 拼图预览图 (preview.png, 1920x1080)
"""

import os
import sys
import hashlib
import numpy as np
from PIL import Image, ImageDraw, ImageFont

# ================= 配置参数 =================
TILE_WIDTH = 960
TILE_HEIGHT = 540
FULL_WIDTH = 1920
FULL_HEIGHT = 1080

BG_COLOR = "#0E1620"        # 深色底 (14, 22, 32)
CYAN_COLOR = "#22D3EE"      # 青色强调 (34, 211, 238)
TITLE_COLOR = "#FFFFFF"     # 白色主标题
SUBTITLE_COLOR = "#94A3B8"  # 灰色副标题
FOOTER_COLOR = "#94A3B8"    # 底部统一灰色

FONT_BOLD_PATH = "C:/Windows/Fonts/msyhbd.ttc"
FONT_REGULAR_PATH = "C:/Windows/Fonts/msyh.ttc"

FONT_SIZE_TITLE = 64
FONT_SIZE_SUBTITLE = 28
FONT_SIZE_BADGE = 96
FONT_SIZE_FOOTER = 22

MARGIN = 24
DECO_BAR_LENGTH = 80
DECO_BAR_THICKNESS = 6

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "menu")

# 4 张卡片内容定义
CARDS_INFO = [
    {
        "index": 0,
        "title": "红绿灯决策",
        "subtitle": "红灯停 · 绿灯行 · 闯红灯报警",
        "badge": "01",
    },
    {
        "index": 1,
        "title": "车道变道",
        "subtitle": "虚线可变道 · 实线强制报警",
        "badge": "02",
    },
    {
        "index": 2,
        "title": "四路感知",
        "subtitle": "四路 1080p · NPU 实时检测",
        "badge": "03",
    },
    {
        "index": 3,
        "title": "行人避让",
        "subtitle": "行人/锥桶进入车道 → 报警",
        "badge": "04",
    },
]

FOOTER_TEXT = "KEY0 切换    KEY1 确认    KEY4 长按退出"


def render_card(info, font_title, font_sub, font_badge, font_bot):
    """使用 PIL 渲染单张 960x540 卡片"""
    img = Image.new("RGB", (TILE_WIDTH, TILE_HEIGHT), BG_COLOR)
    draw = ImageDraw.Draw(img)

    # 1. 四周留 24px 边距，左上角画 6px 青色装饰条
    # x: [24, 24 + 80), y: [24, 24 + 6)
    deco_x0 = MARGIN
    deco_y0 = MARGIN
    deco_x1 = MARGIN + DECO_BAR_LENGTH
    deco_y1 = MARGIN + DECO_BAR_THICKNESS
    draw.rectangle([deco_x0, deco_y0, deco_x1, deco_y1], fill=CYAN_COLOR)

    # 2. 右上角角标 (字号 96, msyhbd.ttc, 青色 #22D3EE)
    badge_text = info["badge"]
    badge_bbox = draw.textbbox((0, 0), badge_text, font=font_badge)
    badge_w = badge_bbox[2] - badge_bbox[0]
    badge_x = TILE_WIDTH - MARGIN - badge_w
    badge_y = MARGIN
    draw.text((badge_x, badge_y), badge_text, font=font_badge, fill=CYAN_COLOR)

    # 3. 大标题 (字号 64, msyhbd.ttc, 白色 #FFFFFF)
    title_text = info["title"]
    title_x = 64
    title_y = 190
    draw.text((title_x, title_y), title_text, font=font_title, fill=TITLE_COLOR)

    # 4. 副标题 (字号 28, msyh.ttc, 灰色 #94A3B8)
    sub_text = info["subtitle"]
    sub_x = 64
    sub_y = 280
    draw.text((sub_x, sub_y), sub_text, font=font_sub, fill=SUBTITLE_COLOR)

    # 5. 底部统一小字「KEY0 切换    KEY1 确认」 (字号 22, msyh.ttc, 居中)
    bot_bbox = draw.textbbox((0, 0), FOOTER_TEXT, font=font_bot)
    bot_w = bot_bbox[2] - bot_bbox[0]
    bot_x = (TILE_WIDTH - bot_w) // 2
    bot_y = TILE_HEIGHT - MARGIN - 30
    draw.text((bot_x, bot_y), FOOTER_TEXT, font=font_bot, fill=FOOTER_COLOR)

    return img


def rgb_to_rgb565(rgb_array):
    """
    转换为 RGB565 小端 (uint16)
    公式: (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)
    """
    r = rgb_array[..., 0].astype(np.uint16)
    g = rgb_array[..., 1].astype(np.uint16)
    b = rgb_array[..., 2].astype(np.uint16)
    val = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    # <u2 表示 16位无符号小端
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
    Y 范围 [16, 235], U/V 范围 [16, 240]
    UV 平面 2:1 水平与垂直下采样, 交叉存储 (U0 V0 U1 V1...)
    """
    r = rgb_array[..., 0].astype(np.float32)
    g = rgb_array[..., 1].astype(np.float32)
    b = rgb_array[..., 2].astype(np.float32)

    # ITU-R BT.601 limited range 转换公式
    y = 16.0 + (65.481 * r + 128.553 * g + 24.966 * b) / 255.0
    u = 128.0 + (-37.797 * r - 74.203 * g + 112.000 * b) / 255.0
    v = 128.0 + (112.000 * r - 93.786 * g - 18.214 * b) / 255.0

    y_plane = np.clip(np.round(y), 16, 235).astype(np.uint8)
    u_clip = np.clip(np.round(u), 16, 240)
    v_clip = np.clip(np.round(v), 16, 240)

    # 4:2:0 2x2 平均下采样
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

    h_uv = TILE_HEIGHT // 2
    w_uv = TILE_WIDTH // 2
    uv_plane = np.empty((h_uv, TILE_WIDTH), dtype=np.uint8)
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
    """计算文件 MD5"""
    hasher = hashlib.md5()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()


def main():
    print("=" * 60)
    print("2026 嵌赛 ADAS 演示 - 四分屏菜单卡片生成")
    print(f"输出目录: {OUTPUT_DIR}")
    print("=" * 60)

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # 加载字体
    font_title = ImageFont.truetype(FONT_BOLD_PATH, FONT_SIZE_TITLE)
    font_sub = ImageFont.truetype(FONT_REGULAR_PATH, FONT_SIZE_SUBTITLE)
    font_badge = ImageFont.truetype(FONT_BOLD_PATH, FONT_SIZE_BADGE)
    font_bot = ImageFont.truetype(FONT_REGULAR_PATH, FONT_SIZE_FOOTER)

    rendered_images = []
    rgb565_arrays = []
    nv12_data_list = []

    # 1. 渲染 4 张卡片并导出二进制文件
    for info in CARDS_INFO:
        idx = info["index"]
        img = render_card(info, font_title, font_sub, font_badge, font_bot)
        rendered_images.append(img)
        rgb_arr = np.array(img)

        # 导出 RGB565
        rgb565_bytes, rgb565_u16 = rgb_to_rgb565(rgb_arr)
        rgb565_path = os.path.join(OUTPUT_DIR, f"tile{idx}.rgb565")
        with open(rgb565_path, "wb") as f:
            f.write(rgb565_bytes)
        rgb565_arrays.append(rgb565_u16)

        # 导出 NV12
        nv12_bytes, y_plane, uv_plane = rgb_to_nv12(rgb_arr)
        nv12_path = os.path.join(OUTPUT_DIR, f"tile{idx}.nv12")
        with open(nv12_path, "wb") as f:
            f.write(nv12_bytes)
        nv12_data_list.append((y_plane, uv_plane))

    # 2. 生成 preview.png 2x2 拼图 (1920x1080)
    preview = Image.new("RGB", (FULL_WIDTH, FULL_HEIGHT))
    preview.paste(rendered_images[0], (0, 0))
    preview.paste(rendered_images[1], (TILE_WIDTH, 0))
    preview.paste(rendered_images[2], (0, TILE_HEIGHT))
    preview.paste(rendered_images[3], (TILE_WIDTH, TILE_HEIGHT))

    preview_path = os.path.join(OUTPUT_DIR, "preview.png")
    preview.save(preview_path, format="PNG")

    # 3. 校验并打印文件信息
    print("\n[生成文件清单、尺寸与 MD5 校验]:")
    generated_files = [
        ("tile0.rgb565", 1036800),
        ("tile1.rgb565", 1036800),
        ("tile2.rgb565", 1036800),
        ("tile3.rgb565", 1036800),
        ("tile0.nv12", 777600),
        ("tile1.nv12", 777600),
        ("tile2.nv12", 777600),
        ("tile3.nv12", 777600),
        ("preview.png", None),  # PNG 动态压缩大小
    ]

    all_exist = True
    sizes_ok = True

    for fname, expected_size in generated_files:
        fpath = os.path.join(OUTPUT_DIR, fname)
        if not os.path.exists(fpath):
            print(f"  [MISSING] {fname} 不存在!")
            all_exist = False
            continue
        actual_size = os.path.getsize(fpath)
        md5_val = get_file_md5(fpath)
        if expected_size is not None and actual_size != expected_size:
            print(f"  [FAIL] {fname}: 大小={actual_size} (预期={expected_size}), MD5={md5_val}")
            sizes_ok = False
        else:
            print(f"  [OK]   {fname:<14} 大小={actual_size:>10} 字节 | MD5={md5_val}")

    print("\n[抽样像素量化误差比对 (容许误差 <= 4)]:")
    max_err_all = 0

    for idx in range(4):
        rgb_orig = np.array(rendered_images[idx])
        rgb565_u16 = rgb565_arrays[idx]
        y_plane, uv_plane = nv12_data_list[idx]

        # 找到卡片主标题笔画中心的一个确定为白色的像素点
        white_pts = np.argwhere(
            (rgb_orig[..., 0] == 255) & (rgb_orig[..., 1] == 255) & (rgb_orig[..., 2] == 255)
        )
        w_py, w_px = white_pts[len(white_pts) // 2]

        sample_coords = [
            (100, 100, "深色背景区"),
            (27, 50,   "青色装饰条"),
            (int(w_py), int(w_px), "白色主标题"),
        ]

        print(f"  --- Tile {idx} ({CARDS_INFO[idx]['title']}) ---")
        for py, px, desc in sample_coords:
            orig_rgb = rgb_orig[py, px]

            # 解码 RGB565
            u16_val = rgb565_u16[py, px]
            dec_rgb565 = decode_rgb565(u16_val)
            err_rgb565 = int(np.max(np.abs(orig_rgb.astype(int) - dec_rgb565.astype(int))))

            # 解码 NV12
            dec_nv12 = decode_nv12_pixel(y_plane, uv_plane, py, px)
            err_nv12 = int(np.max(np.abs(orig_rgb.astype(int) - dec_nv12.astype(int))))

            max_err_all = max(max_err_all, err_rgb565, err_nv12)

            print(
                f"    点({px:>3},{py:>3}) [{desc}]: "
                f"原图RGB={orig_rgb} | "
                f"RGB565解码={dec_rgb565} (误差={err_rgb565}) | "
                f"NV12解码={dec_nv12} (误差={err_nv12})"
            )

    print(f"\n抽样像素最大误差: {max_err_all} (约束要求 <= 4)")

    # 5. 验收断言
    if not all_exist:
        print("[ERROR] 部分文件缺失!")
        sys.exit(1)
    if not sizes_ok:
        print("[ERROR] 文件尺寸不符合规范!")
        sys.exit(2)
    if max_err_all > 4:
        print(f"[ERROR] 抽样像素最大误差 {max_err_all} 超出容许范围 4!")
        sys.exit(3)

    print("\n[SUCCESS] 全部验收条件达成，退出码 0。")
    sys.exit(0)


if __name__ == "__main__":
    main()
