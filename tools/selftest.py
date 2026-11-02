#!/usr/bin/env python3
"""selftest.py — 提交前自检：交叉构建 + 脚本语法 + 文档不变量 + 资产完整性。

用法（仓库根目录）：
    python tools/selftest.py            # 全量
    python tools/selftest.py --quick    # 跳过 usb_feed（最慢的一项）

退出码：0 = 全通过；1 = 有失败项。
"""
from __future__ import annotations

import argparse
import contextlib
import glob
import io
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
    "tools/usb_feed/nav.c",
    "tools/usb_feed/fcam_rb_lib.c",
    "tools/usb_feed/lane_cls.c",
    "tools/usb_feed/usb_night.c",
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

BANNED_OLD_VERSION = ["cam11", "quad_cam11", "build_cam11", "+0.340 ns"]
# 白名单豁免“历史说明”类句子：每项为 (文件相对路径或文件名子串, 行内容子串)
OLD_VERSION_WHITELIST: list[tuple[str, str]] = []

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

    for name in ("附录A_寄存器映射.md", "附录B_验证复现.md", "演示视频_分镜.md", "答辩要点_评委问答.md", "演示现场运行手册.md", "提交清单与待办.md"):
        p = os.path.join(ROOT, "docs", name)
        record(f"doc:{name}", os.path.isfile(p))


def check_assets() -> None:
    for rel, min_size in (("tools/menu/ui_assets.h", 20_000),
                          ("menu/ui_cjk.bin", 1_500_000),
                          ("docs/ref_zh2.docx", 5_000)):
        p = os.path.join(ROOT, rel)
        ok = os.path.isfile(p) and os.path.getsize(p) >= min_size
        record(f"asset:{rel}", ok, f"{os.path.getsize(p)} B" if os.path.isfile(p) else "missing")


def is_old_version_whitelisted(rel_path: str, line_str: str) -> bool:
    for wl_file, wl_substr in OLD_VERSION_WHITELIST:
        if (wl_file in rel_path or wl_file in os.path.basename(rel_path)) and wl_substr in line_str:
            return True
    return False


def get_package_entries() -> dict[str, str]:
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    from make_submit_package import collect_whitelist_files

    with contextlib.redirect_stdout(io.StringIO()):
        try:
            return collect_whitelist_files(ROOT, with_assets=True)
        except SystemExit:
            return collect_whitelist_files(ROOT, with_assets=False)


def check_banned_old_version(entries: dict[str, str]) -> None:
    packaged_mds = [
        path for arc, path in entries.items()
        if arc.startswith("docs/") and arc.endswith(".md")
    ]
    submit_mds = glob.glob(os.path.join(ROOT, "docs", "submit", "*.md"))
    target_docs = sorted(set(os.path.abspath(p) for p in (packaged_mds + submit_mds)))

    violations: list[tuple[str, int, list[str], str]] = []
    for doc_path in target_docs:
        rel_path = os.path.relpath(doc_path, ROOT).replace("\\", "/")
        try:
            with open(doc_path, "r", encoding="utf-8", errors="ignore") as f:
                for line_no, line in enumerate(f, 1):
                    matched = [w for w in BANNED_OLD_VERSION if w in line]
                    if not matched:
                        continue
                    if not is_old_version_whitelisted(rel_path, line):
                        violations.append((rel_path, line_no, matched, line.strip()))
        except Exception as e:
            violations.append((rel_path, 0, [f"read_error: {e}"], ""))

    if violations:
        record("doc:no-banned-old-version", False, f"{len(violations)} violations")
        for rel_path, line_no, matched, line_content in violations:
            print(f"  {rel_path}:{line_no}: banned {matched} -> {line_content[:80]}")
    else:
        record("doc:no-banned-old-version", True)


def check_package_contents(entries: dict[str, str]) -> None:
    errors: list[str] = []

    # 1. 断言必含条目
    required_files = [
        "tools/menu/S99adas_menu",
        "tools/menu/run_boot.sh",
        "docs/submit/README.md",
    ]
    for req in required_files:
        if req not in entries:
            errors.append(f"missing required file: {req}")

    # 2. 断言不含文件名包含“草稿”或“大纲”的文件
    for arc_name in entries:
        base = os.path.basename(arc_name)
        if "草稿" in base or "大纲" in base:
            errors.append(f"forbidden draft/outline file in package: {arc_name}")

    # 3. 断言包内 .sh 与 S99adas_menu 不含 \r
    for arc_name, abs_path in sorted(entries.items()):
        base = os.path.basename(arc_name)
        if arc_name.endswith(".sh") or base == "S99adas_menu":
            if not os.path.isfile(abs_path):
                errors.append(f"{arc_name}: file not found on disk: {abs_path}")
                continue
            with open(abs_path, "rb") as f:
                content = f.read()
            if b"\r" in content:
                for line_no, line in enumerate(content.split(b"\n"), 1):
                    if b"\r" in line:
                        errors.append(f"{arc_name}:{line_no}: contains CR (\\r)")

    if errors:
        record("pkg:contents", False, f"{len(errors)} issues")
        for err in errors:
            print(f"  {err}")
    else:
        record("pkg:contents", True)


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
    entries = get_package_entries()
    check_banned_old_version(entries)
    check_package_contents(entries)

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
