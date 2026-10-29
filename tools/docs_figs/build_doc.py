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


def col_min_cm(texts: list[str]) -> float:
    """按最长不可断词估算该列最小宽度（cm），避免 0x804 / DISP_CTRL 被折断。"""
    longest = 0.0
    for text in texts:
        for token in re.split(r"[\s，。；、（）()【】]+", text):
            if not token:
                continue
            width = sum(0.38 if ord(ch) > 127 else 0.24 for ch in token) + 0.45
            longest = max(longest, width)
    return min(max(longest, 1.8), 3.2)


def fix_tables(docx_path: str, text_width_cm: float = 16.0) -> int:
    """按内容长度重设列宽，并让首行跨页重复。返回处理的表格数。"""
    from docx import Document
    from docx.shared import Cm
    from docx.oxml.ns import qn

    doc = Document(docx_path)
    caps = [95, 55, 115, 70, 60, 60]
    n_tables = 0
    for table in doc.tables:
        # pandoc 有时写出比实际单元格多一列的 tblGrid（gridSpan 被 python-docx 展开成重复单元格）；
        # 以 XML 中真实的 <w:tc> 数量为准并重建网格。
        trs = table._tbl.tr_lst
        ncol = len(trs[0].tc_lst) if trs else 0
        if ncol == 0:
            continue
        grid = table._tbl.tblGrid
        if grid is not None:
            for gc in list(grid):
                grid.remove(gc)
            for _ in range(ncol):
                gc = grid.makeelement(qn("w:gridCol"), {})
                gc.set(qn("w:w"), "1000")
                grid.append(gc)
        max_w = [0] * ncol
        for row in table.rows:
            for k, cell in enumerate(row.cells[:ncol]):
                max_w[k] = max(max_w[k], char_weight(cell.text))
        weights = [max(4, max_w[k]) for k in range(ncol)]
        total = sum(weights) or 1
        widths = [max(1.2, text_width_cm * w / total) for w in weights]

        # 列宽下限：按该列最长不可断词估算，避免地址/寄存器名被折断
        col_texts = [[row.cells[k].text for row in table.rows] for k in range(ncol)]
        mins = [col_min_cm(col_texts[k]) for k in range(ncol)]
        # 先保住每列下限，再把剩余宽度按内容权重分配，避免归一化把下限缩回去
        mins_sum = sum(mins)
        if mins_sum >= text_width_cm:
            widths = [m * text_width_cm / mins_sum for m in mins]
        else:
            extra = text_width_cm - mins_sum
            wsum = sum(weights) or 1
            widths = [mins[k] + extra * weights[k] / wsum for k in range(ncol)]

        table.autofit = False
        for k in range(ncol):
            table.columns[k].width = Cm(widths[k])
        for tr in trs:
            for k, tc in enumerate(tr.tc_lst[:ncol]):
                tc.width = Cm(widths[k])

        # 列数多的表（寄存器/对照表）字号降到 9 pt，缓解窄列折行
        if ncol >= 5:
            from docx.shared import Pt
            for row in table.rows:
                for cell in row.cells:
                    for para in cell.paragraphs:
                        for run in para.runs:
                            run.font.size = Pt(9)

        # 首行跨页重复
        tr_pr = table.rows[0]._tr.get_or_add_trPr()
        if tr_pr.find(qn("w:tblHeader")) is None:
            tr_pr.append(tr_pr.makeelement(qn("w:tblHeader"), {}))
        n_tables += 1
    # 章与附录另起一页，避免表格在页底被跨页拆行
    for para in doc.paragraphs:
        name = (para.style.name or "").lower()
        text = para.text.strip()
        if name.startswith("heading") and (re.match(r"^第[零一二三四五六七八九十]+章", text) or text.startswith("附录")):
            para.paragraph_format.page_break_before = True

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
