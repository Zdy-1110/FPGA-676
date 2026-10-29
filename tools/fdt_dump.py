#!/usr/bin/env python3
"""Minimal FDT (flattened device tree) dumper using only the Python stdlib.

Usage: py -3 tools/fdt_dump.py <input.dtb|fit-head.bin> <output.txt>

Only bytes inside the FDT header's totalsize are parsed, so a truncated
container that starts with a FIT/FDT structure (external data) still works.
"""

import struct
import sys

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 0x1
FDT_END_NODE = 0x2
FDT_PROP = 0x3
FDT_NOP = 0x4
FDT_END = 0x9

MAX_PROP = 256
PREVIEW = 64


class FdtError(Exception):
    pass


def align4(value):
    return (value + 3) & ~3


def u32(buf, off):
    if off < 0 or off + 4 > len(buf):
        raise FdtError(
            "读取 u32 越界: offset=0x%x, file_size=0x%x" % (off, len(buf))
        )
    return struct.unpack_from(">I", buf, off)[0]


def u64(buf, off):
    if off < 0 or off + 8 > len(buf):
        raise FdtError(
            "读取 u64 越界: offset=0x%x, file_size=0x%x" % (off, len(buf))
        )
    return struct.unpack_from(">Q", buf, off)[0]


def parse_header(buf):
    if len(buf) < 28:
        raise FdtError("文件太小，不足 FDT 头 (28 字节)")
    magic = u32(buf, 0)
    if magic != FDT_MAGIC:
        raise FdtError("FDT 魔数错误: 0x%08x != 0xd00dfeed" % magic)
    totalsize = u32(buf, 4)
    off_struct = u32(buf, 8)
    off_strings = u32(buf, 12)
    off_rsvmap = u32(buf, 16)
    version = u32(buf, 20)
    last_comp = u32(buf, 24)
    if version >= 17 and len(buf) >= 40:
        boot_cpuid = u32(buf, 28)
        size_strings = u32(buf, 32)
        size_struct = u32(buf, 36)
    elif version >= 16 and len(buf) >= 36:
        boot_cpuid = u32(buf, 28)
        size_strings = u32(buf, 32)
        size_struct = 0
    else:
        boot_cpuid = 0
        size_strings = 0
        size_struct = 0

    if totalsize < 40 or totalsize > len(buf):
        raise FdtError(
            "totalsize 非法: 0x%x (文件 0x%x 字节)" % (totalsize, len(buf))
        )
    for name, off in (
        ("off_dt_struct", off_struct),
        ("off_dt_strings", off_strings),
        ("off_mem_rsvmap", off_rsvmap),
    ):
        if off >= totalsize:
            raise FdtError("%s 越界: 0x%x >= totalsize 0x%x" % (name, off, totalsize))

    return {
        "totalsize": totalsize,
        "off_struct": off_struct,
        "off_strings": off_strings,
        "off_rsvmap": off_rsvmap,
        "version": version,
        "last_comp": last_comp,
        "boot_cpuid": boot_cpuid,
        "size_strings": size_strings,
        "size_struct": size_struct,
    }


def read_cstr(buf, off, limit, what):
    if off < 0 or off >= limit:
        raise FdtError("%s 起点越界: offset=0x%x, limit=0x%x" % (what, off, limit))
    end = buf.find(b"\0", off, limit)
    if end < 0:
        raise FdtError("%s 未找到 NUL 结尾: offset=0x%x, limit=0x%x" % (what, off, limit))
    return buf[off:end]


def is_all_strings(value):
    if not value or value[-1] != 0:
        return False
    parts = value.split(b"\0")[:-1]
    for part in parts:
        for byte in part:
            if byte < 0x20 or byte > 0x7E:
                return False
    while parts and parts[-1] == b"":
        parts.pop()
    return bool(parts)


def decode_value(value):
    if not value:
        return None
    if is_all_strings(value):
        parts = value.split(b"\0")[:-1]
        while parts and parts[-1] == b"":
            parts.pop()
        return " ".join('"%s"' % p.decode("ascii") for p in parts)
    if len(value) % 4 == 0:
        words = struct.unpack(">%dI" % (len(value) // 4), value)
        return "<%s>" % " ".join("0x%x" % w for w in words)
    return "[%s]" % " ".join("%02x" % b for b in value)


def format_prop(name, value):
    if not value:
        return "%s;" % name
    if len(value) > MAX_PROP:
        preview = " ".join("%02x" % b for b in value[:PREVIEW])
        return "%s = /* 0x%x bytes, first 0x40: */ [%s];" % (
            name,
            len(value),
            preview,
        )
    return "%s = %s;" % (name, decode_value(value))


def parse_tree(buf, hdr):
    totalsize = hdr["totalsize"]
    off_struct = hdr["off_struct"]
    off_strings = hdr["off_strings"]
    if hdr["size_strings"]:
        strings_limit = off_strings + hdr["size_strings"]
        if strings_limit > totalsize:
            raise FdtError(
                "字符串块越界: 0x%x > totalsize 0x%x" % (strings_limit, totalsize)
            )
    else:
        strings_limit = totalsize

    lines = []
    pos = off_struct
    depth = 0
    seen_end = False

    while True:
        if pos + 4 > totalsize:
            raise FdtError(
                "结构块越界: token 位置 0x%x + 4 > totalsize 0x%x"
                % (pos, totalsize)
            )
        token = u32(buf, pos)
        pos += 4
        if token == FDT_BEGIN_NODE:
            name = read_cstr(buf, pos, totalsize, "节点名")
            pos = align4(pos + len(name) + 1)
            if name:
                lines.append("    " * depth + "%s {" % name.decode("latin-1"))
            else:
                lines.append("/ {")
            depth += 1
        elif token == FDT_END_NODE:
            if depth <= 0:
                raise FdtError("END_NODE 无匹配: 位置 0x%x" % (pos - 4))
            depth -= 1
            lines.append("    " * depth + "};")
        elif token == FDT_PROP:
            if depth <= 0:
                raise FdtError("PROP 出现在根节点之外: 位置 0x%x" % (pos - 4))
            plen = u32(buf, pos)
            nameoff = u32(buf, pos + 4)
            pos += 8
            if plen > totalsize or pos + plen > totalsize:
                raise FdtError(
                    "属性值越界: 位置 0x%x, len=0x%x, totalsize=0x%x"
                    % (pos, plen, totalsize)
                )
            value = bytes(buf[pos:pos + plen])
            pos = align4(pos + plen)
            name_off = off_strings + nameoff
            pname = read_cstr(buf, name_off, strings_limit, "属性名").decode("latin-1")
            lines.append("    " * depth + format_prop(pname, value))
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            seen_end = True
            break
        else:
            raise FdtError("未知 token 0x%x, 位置 0x%x" % (token, pos - 4))

    if depth != 0:
        raise FdtError("结构块结束时节点未闭合, 剩余深度 %d" % depth)
    if not seen_end:
        raise FdtError("结构块缺少 FDT_END")
    return lines


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("用法: py -3 tools/fdt_dump.py <输入文件> <输出 txt>\n")
        return 1
    src, dst = argv[1], argv[2]
    with open(src, "rb") as f:
        buf = f.read()

    lines = []
    error = None
    hdr = None
    try:
        hdr = parse_header(buf)
        lines.append(
            "/* FDT totalsize=0x%x (%d bytes) version=%d boot_cpuid=0x%x */"
            % (
                hdr["totalsize"],
                hdr["totalsize"],
                hdr["version"],
                hdr["boot_cpuid"],
            )
        )
        lines.append("/dts-v1/;")
        lines.append("")
        lines.extend(parse_tree(buf, hdr))
    except FdtError as exc:
        error = str(exc)

    if error:
        lines.append("/* PARSE ERROR: %s */" % error)

    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    if error:
        sys.stderr.write("解析失败: %s\n" % error)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
