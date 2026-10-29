#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_ui_font.py
生成 1920x1080 U盘视频流界面的 UI 字体与中文位图素材头文件 tools/menu/ui_assets.h
包含：
  - Consolas 等宽 ASCII 字模 (32~126)
  - 微软雅黑固定中文标签 1-bit 位图
"""

import os
import sys
from PIL import Image, ImageDraw, ImageFont

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_HEADER = os.path.join(SCRIPT_DIR, "ui_assets.h")

FONT_ASCII_PATH = "C:/Windows/Fonts/consola.ttf"
FONT_ZH_BOLD_PATH = "C:/Windows/Fonts/msyhbd.ttc"

ASCII_FONT_SIZE = 28
ASCII_WIDTH = 15
ASCII_HEIGHT = 30
ASCII_PITCH = (ASCII_WIDTH + 7) // 8  # 2 字节

ZH_LABELS = [
    ("ui_lbl_title", "U盘视频流", 34),
    ("ui_lbl_subtitle", "选择 1~4 个视频，按选择顺序分屏播放", 26),
    ("ui_lbl_selected", "已选", 26),
    ("ui_lbl_start_play", "开始播放", 26),
    ("ui_lbl_key_hint", "KEY0 移动  KEY1 选择/进入  KEY4 返回", 26),
    ("ui_lbl_no_usb", "未检测到 U 盘，插入后按 KEY1 重试", 26),
    ("ui_lbl_max_videos", "最多选择 4 个视频", 26),
    ("ui_lbl_playing_hint", "播放中，长按 KEY4 停止", 26),
    ("ui_lbl_no_signal", "无信号", 26),
]


def format_c_bytes(data: bytes, indent: str = "    ", per_line: int = 16) -> str:
    lines = []
    for i in range(0, len(data), per_line):
        chunk = data[i:i + per_line]
        hex_vals = [f"0x{b:02X}" for b in chunk]
        lines.append(indent + ", ".join(hex_vals))
    return ",\n".join(lines)


def main():
    if not os.path.exists(FONT_ASCII_PATH):
        print(f"Error: ASCII font not found: {FONT_ASCII_PATH}", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(FONT_ZH_BOLD_PATH):
        print(f"Error: Chinese font not found: {FONT_ZH_BOLD_PATH}", file=sys.stderr)
        sys.exit(1)

    font_ascii = ImageFont.truetype(FONT_ASCII_PATH, ASCII_FONT_SIZE)

    print("=== 生成 ASCII 字模 (Consolas 28pt) ===")
    ascii_bytes_list = []
    for code in range(32, 127):
        im = Image.new("1", (ASCII_WIDTH, ASCII_HEIGHT), 0)
        draw = ImageDraw.Draw(im)
        draw.text((0, 1), chr(code), font=font_ascii, fill=1)
        raw = im.tobytes()
        ascii_bytes_list.append(raw)

    print(f"ASCII: 字符 32..126 (共 95 个), 尺寸 {ASCII_WIDTH}x{ASCII_HEIGHT}, 行跨距 {ASCII_PITCH} 字节, 总计 {len(ascii_bytes_list) * len(ascii_bytes_list[0])} 字节")

    print("\n=== 生成固定中文标签 (微软雅黑粗体) ===")
    zh_results = []
    for var_name, text, font_size in ZH_LABELS:
        font_zh = ImageFont.truetype(FONT_ZH_BOLD_PATH, font_size)
        bbox = font_zh.getbbox(text)
        w = bbox[2] - bbox[0]
        h = bbox[3] - bbox[1]
        im = Image.new("1", (w, h), 0)
        draw = ImageDraw.Draw(im)
        draw.text((-bbox[0], -bbox[1]), text, font=font_zh, fill=1)
        raw = im.tobytes()
        pitch = (w + 7) // 8
        zh_results.append({
            "var_name": var_name,
            "text": text,
            "font_size": font_size,
            "width": w,
            "height": h,
            "pitch": pitch,
            "data": raw,
        })
        print(f"[{var_name}] \"{text}\": 字号 {font_size}, 尺寸 {w}x{h}, 行跨距 {pitch} 字节, 数据量 {len(raw)} 字节")

    # 写入 ui_assets.h
    header_content = []
    header_content.append("/* 自动生成素材头文件 - 由 gen_ui_font.py 生成，请勿手动修改 */")
    header_content.append("#ifndef UI_ASSETS_H")
    header_content.append("#define UI_ASSETS_H\n")
    header_content.append("#include <stdint.h>\n")
    header_content.append("typedef struct {")
    header_content.append("    uint16_t width;")
    header_content.append("    uint16_t height;")
    header_content.append("    uint16_t pitch;")
    header_content.append("    const uint8_t *bitmap;")
    header_content.append("} ui_bitmap_t;\n")
    header_content.append("#define UI_ASCII_FIRST  32")
    header_content.append("#define UI_ASCII_LAST   126")
    header_content.append("#define UI_ASCII_COUNT  95")
    header_content.append(f"#define UI_ASCII_WIDTH  {ASCII_WIDTH}")
    header_content.append(f"#define UI_ASCII_HEIGHT {ASCII_HEIGHT}")
    header_content.append(f"#define UI_ASCII_PITCH  {ASCII_PITCH}\n")

    # ASCII 字模数据
    header_content.append(f"static const uint8_t ui_ascii_bitmaps[UI_ASCII_COUNT][UI_ASCII_HEIGHT * UI_ASCII_PITCH] = {{")
    for idx, raw in enumerate(ascii_bytes_list):
        code = 32 + idx
        ch_repr = chr(code)
        if ch_repr == '\\':
            ch_str = "'\\\\'"
        elif ch_repr == '\'':
            ch_str = "'\\''"
        else:
            ch_str = f"'{ch_repr}'"
        header_content.append(f"    /* {code} {ch_str} */")
        header_content.append("    {")
        header_content.append(format_c_bytes(raw, indent="        ", per_line=16))
        if idx < len(ascii_bytes_list) - 1:
            header_content.append("    },")
        else:
            header_content.append("    }")
    header_content.append("};\n")

    # 中文标签位图数据
    for item in zh_results:
        var = item["var_name"]
        text = item["text"]
        w = item["width"]
        h = item["height"]
        pitch = item["pitch"]
        data = item["data"]
        header_content.append(f"/* 中文标签: \"{text}\" ({w}x{h}) */")
        header_content.append(f"static const uint8_t {var}_data[{len(data)}] = {{")
        header_content.append(format_c_bytes(data, indent="    ", per_line=16))
        header_content.append("};")
        header_content.append(f"static const ui_bitmap_t {var} = {{ {w}, {h}, {pitch}, {var}_data }};\n")

    header_content.append("#endif /* UI_ASSETS_H */\n")

    with open(OUTPUT_HEADER, "w", encoding="utf-8") as f:
        f.write("\n".join(header_content))

    print(f"\n成功生成: {OUTPUT_HEADER} (文件大小: {os.path.getsize(OUTPUT_HEADER)} 字节)")
    sys.exit(0)


if __name__ == "__main__":
    main()
