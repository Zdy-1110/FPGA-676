#!/usr/bin/env python3
"""selftest.py — 提交前自检：交叉构建 + 脚本语法 + 文档不变量 + 资产完整性。

用法（仓库根目录）：
    python tools/selftest.py            # 全量
    python tools/selftest.py --quick    # 跳过 usb_feed（最慢的一项）

退出码：0 = 全通过；1 = 有失败项。
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = os.environ.get("TEMP", "/tmp")

BUILD_TARGETS = [
    ("menu_daemon", ["tools/menu/menu_daemon.c", "-lpthread", "-Wextra"]),
    ("mode_select", ["tools/menu/mode_select.c", "-Wextra"]),
    ("usb_menu", ["tools/menu/usb_menu.c", "-Wextra"]),
]

FEED_SOURCES = [
    "tools/usb_feed/usb_feed.c",
    "tools/usb_feed/vdec_mpp.c",
    "tools/usb_feed/quad_npu.c",
    "tools/usb_feed/quad_sched.c",
    "tools/usb_feed/adas.c",
    "tools/adas/tl_det.c",
    "tools/npu_det/npu_post.c",
    "-I", "tools/npu_det", "-I", "tools/adas",
    "-I", "third_party/librga-1.9.1/include",
    "-lrockchip_mpp",
    "third_party/rk_sysroot/usr/lib/librga.so.2.1.0",
    "-lrknnrt", "-lpthread", "-lm", "-std=gnu99", "-Wextra",
]

BANNED_IN_DOC = ["YOLOv8n", "KEY_UP", "KEY_DOWN", "KEY_CENTER", "1.2 µs", "<1.2 ms"]
FIGURES = [
    "fig1_system.png", "fig2_dataflow.png", "fig3_boot.png",
    "fig4_fbmap.png", "fig5_keys.png", "fig6_fpga.png",
]

results: list[tuple[str, bool, str]] = []


def record(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, ok, detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))


def build(name: str, args: list[str]) -> None:
    out = os.path.join(TMP, f"st_{name}")
    cmd = ["sh", "tools/rk_build.sh", out] + args
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    detail = ""
    if p.returncode != 0:
        detail = (p.stderr or p.stdout).strip().splitlines()[-1:] or [""]
        detail = detail[0]
    record(f"build:{name}", p.returncode == 0, detail)


def check_sh_syntax(path: str) -> None:
    p = subprocess.run(["sh", "-n", path], cwd=ROOT, capture_output=True, text=True)
    record(f"sh -n:{path}", p.returncode == 0, (p.stderr or "").strip()[:120])


def check_docs() -> None:
    md = os.path.join(ROOT, "docs", "技术文档_最终稿.md")
    if not os.path.isfile(md):
        record("doc:final", False, "missing docs/技术文档_最终稿.md")
        return
    text = open(md, encoding="utf-8").read()
    record("doc:final", True, f"{len(text)} chars")

    chapters = re.findall(r"^## 第[零一二三四五六七八九十]+章", text, re.M)
    record("doc:chapters", len(chapters) >= 13, f"{len(chapters)} chapters")

    bad = [b for b in BANNED_IN_DOC if b in text]
    record("doc:no-banned", not bad, ", ".join(bad))

    missing = [f for f in FIGURES if not os.path.isfile(os.path.join(ROOT, "docs", "figs", f))]
    record("doc:figures", not missing, ", ".join(missing))

    for name in ("附录A_寄存器映射.md", "附录B_验证复现.md", "演示视频_分镜.md", "答辩要点_评委问答.md", "演示现场运行手册.md"):
        p = os.path.join(ROOT, "docs", name)
        record(f"doc:{name}", os.path.isfile(p))


def check_assets() -> None:
    for rel, min_size in (("tools/menu/ui_assets.h", 20_000),
                          ("menu/ui_cjk.bin", 1_500_000),
                          ("docs/ref_zh2.docx", 5_000)):
        p = os.path.join(ROOT, rel)
        ok = os.path.isfile(p) and os.path.getsize(p) >= min_size
        record(f"asset:{rel}", ok, f"{os.path.getsize(p)} B" if os.path.isfile(p) else "missing")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="skip usb_feed build")
    args = ap.parse_args()

    if shutil.which("sh") is None:
        print("sh not found (git-bash required)", file=sys.stderr)
        return 2

    for name, extra in BUILD_TARGETS:
        build(name, extra)
    if not args.quick:
        build("usb_feed", FEED_SOURCES)

    check_sh_syntax("tools/menu/run_boot.sh")
    check_sh_syntax("tools/menu/S99adas_menu")
    check_docs()
    check_assets()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
