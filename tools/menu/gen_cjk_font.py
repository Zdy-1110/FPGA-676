#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_cjk_font.py
生成 GBK 汉字 26x26 1-bit 位图字库二进制文件 menu/ui_cjk.bin
格式:
  - magic: 'CJK1' (4B)
  - count: uint32 (4B, 小端)
  - index table: count * { uint32 cp, uint32 offset } (按 cp 升序, offset 相对数据区起点)
  - bitmap data: count * 104B (每字 26 行 x 4 字节, 行内低 26 位有效, MSB 在前, 小端存储)
"""

import os
import sys
import struct
from PIL import Image, ImageDraw, ImageFont

FONT_PATH = "C:/Windows/Fonts/msyh.ttc"
FONT_SIZE = 24  # 24pt 在 26x26 画布内居中渲染汉字效果清晰匀称
CANVAS_SIZE = 26
BYTES_PER_CHAR = CANVAS_SIZE * 4  # 104 字节

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))
OUTPUT_PATH = os.path.join(PROJECT_ROOT, "menu", "ui_cjk.bin")


def main():
    if not os.path.exists(FONT_PATH):
        print(f"Error: Font not found: {FONT_PATH}", file=sys.stderr)
        sys.exit(1)

    print("=== 扫描 GBK 双字节区字符 ===")
    char_set = {}
    for hi in range(0x81, 0xFF):
        for lo in range(0x40, 0xFF):
            if lo == 0x7F:
                continue
            try:
                ch = bytes([hi, lo]).decode("gbk")
                cp = ord(ch)
                if cp not in char_set:
                    char_set[cp] = ch
            except UnicodeDecodeError:
                pass

    sorted_cps = sorted(char_set.keys())
    count = len(sorted_cps)
    print(f"共获取到 {count} 个唯一 GBK 码点字符")

    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)

    print(f"=== 渲染字符位图 (26x26 1-bit, 居中, 阈值 128) ===")
    index_entries = []
    bitmap_data = bytearray()

    for idx, cp in enumerate(sorted_cps):
        ch = char_set[cp]
        offset = idx * BYTES_PER_CHAR
        index_entries.append((cp, offset))

        # 渲染单个字符
        im = Image.new("L", (CANVAS_SIZE, CANVAS_SIZE), 0)
        bb = font.getbbox(ch)
        if bb and bb[2] > bb[0] and bb[3] > bb[1]:
            w = bb[2] - bb[0]
            h = bb[3] - bb[1]
            x_off = (CANVAS_SIZE - w) // 2 - bb[0]
            y_off = (CANVAS_SIZE - h) // 2 - bb[1]
            draw = ImageDraw.Draw(im)
            draw.text((x_off, y_off), ch, font=font, fill=255)

        # 转换为 26 行 x 4 字节 (每行低 26 位有效, MSB 在前, 小端 uint32)
        pix = im.load()
        for r in range(CANVAS_SIZE):
            row_u32 = 0
            for c in range(CANVAS_SIZE):
                if pix[c, r] >= 128:
                    row_u32 |= (1 << (25 - c))
            bitmap_data.extend(struct.pack("<I", row_u32))

    # 组装输出文件
    header = bytearray()
    header.extend(b"CJK1")
    header.extend(struct.pack("<I", count))

    index_table = bytearray()
    for cp, offset in index_entries:
        index_table.extend(struct.pack("<II", cp, offset))

    out_dir = os.path.dirname(OUTPUT_PATH)
    if not os.path.exists(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    with open(OUTPUT_PATH, "wb") as f:
        f.write(header)
        f.write(index_table)
        f.write(bitmap_data)

    file_size = os.path.getsize(OUTPUT_PATH)
    print(f"字库生成成功: {OUTPUT_PATH}")
    print(f"字数: {count}, 文件大小: {file_size} 字节 ({file_size / (1024*1024):.2f} MB)")
    sys.exit(0)


if __name__ == "__main__":
    main()
