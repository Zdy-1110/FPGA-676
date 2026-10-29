#!/usr/bin/env python3
"""build_doc.py — 技术文档最终稿：Markdown → DOCX → PDF 一键构建。

用法（在仓库根目录）：
    python tools/docs_figs/build_doc.py
    python tools/docs_figs/build_doc.py --md docs/技术文档_最终稿.md --no-pdf

依赖：
    - pandoc 在 PATH 中
    - python-docx
    - LibreOffice（仅生成 PDF 时需要，可用 --soffice 指定 soffice.com 路径）

处理内容：
    1. pandoc 按 docs/ref_zh2.docx 样式（SimSun/SimHei）生成 DOCX；
    2. 修正 pandoc 输出表格一律等宽的问题：按各列内容长度重算列宽；
    3. 给每个表格的首行加 w:tblHeader，跨页时重复表头；
    4. 调用 LibreOffice 转 PDF。
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys


def char_weight(text: str) -> int:
    """中文按 2、其它按 1 计宽，粗略反映显示宽度。"""
    text = re.sub(r"\*\*|`|\$", "", text)
    return sum(2 if ord(ch) > 127 else 1 for ch in text)


def fix_tables(docx_path: str, text_width_cm: float = 16.0) -> int:
    """按内容长度重设列宽，并让首行跨页重复。返回处理的表格数。"""
    from docx import Document
    from docx.shared import Cm
    from docx.oxml.ns import qn

    doc = Document(docx_path)
    caps = [95, 55, 115, 70, 60, 60]
    n_tables = 0
    for table in doc.tables:
        ncol = len(table.columns)
        if ncol == 0:
            continue
        max_w = [0] * ncol
        for row in table.rows:
            for k, cell in enumerate(row.cells[:ncol]):
                max_w[k] = max(max_w[k], char_weight(cell.text))
        weights = [min(max_w[k], caps[k] if k < len(caps) else 90) for k in range(ncol)]
        total = sum(weights) or 1
        widths = [max(1.2, text_width_cm * w / total) for w in weights]
        scale = text_width_cm / sum(widths)
        widths = [w * scale for w in widths]

        table.autofit = False
        for k in range(ncol):
            table.columns[k].width = Cm(widths[k])
            for row in table.rows:
                row.cells[k].width = Cm(widths[k])

        # 首行跨页重复
        tr_pr = table.rows[0]._tr.get_or_add_trPr()
        if tr_pr.find(qn("w:tblHeader")) is None:
            tr_pr.append(tr_pr.makeelement(qn("w:tblHeader"), {}))
        n_tables += 1
    doc.save(docx_path)
    return n_tables


def run(cmd: list[str]) -> int:
    print("+", " ".join(cmd))
    return subprocess.call(cmd)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", default="docs/技术文档_最终稿.md")
    ap.add_argument("--docx", default="docs/技术文档_最终稿.docx")
    ap.add_argument("--reference", default="docs/ref_zh2.docx")
    ap.add_argument("--resource-path", default="docs")
    ap.add_argument("--soffice", default=r"C:\Program Files\LibreOffice\program\soffice.com")
    ap.add_argument("--no-pdf", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.md):
        print(f"missing markdown: {args.md}", file=sys.stderr)
        return 2
    if shutil.which("pandoc") is None:
        print("pandoc not found in PATH", file=sys.stderr)
        return 2

    rc = run(["pandoc", args.md, "-o", args.docx,
              "--reference-doc", args.reference,
              "--resource-path", args.resource_path])
    if rc != 0:
        return rc

    n = fix_tables(args.docx)
    print(f"tables fixed: {n}")

    if not args.no_pdf:
        if not os.path.isfile(args.soffice):
            print(f"soffice not found: {args.soffice} (use --no-pdf)", file=sys.stderr)
            return 3
        outdir = os.path.dirname(args.docx) or "."
        rc = run([args.soffice, "--headless", "--convert-to", "pdf",
                  "--outdir", outdir, args.docx])
        if rc != 0:
            return rc
    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
