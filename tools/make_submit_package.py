#!/usr/bin/env python3
"""
make_submit_package.py - 竞赛源码提交包打包脚本 (Python 3 标准库)

Usage:
    python tools/make_submit_package.py [--out PATH] [--dry-run] [--with-assets | --without-assets]
"""

import argparse
import datetime
import glob
import os
import re
import sys
import zipfile

SECRET_KEYWORDS = ["password", "passwd", "token", "api_key", "secret"]
SECRET_PATTERN = re.compile(r"\b(" + "|".join(SECRET_KEYWORDS) + r")\b", re.IGNORECASE)

TEXT_EXTENSIONS = {
    ".c", ".h", ".v", ".sv", ".vh", ".py", ".sh", ".json", ".md",
    ".tcl", ".fdc", ".pds", ".txt", ".idf", ".csv", ".yaml", ".yml",
    ".toml", ".ini", ".conf", ".cfg"
}

# 运行时内置最小模板（当 docs/submit/ 下对应文件不存在时兜底使用）
BUILTIN_TEMPLATES = {
    "README.md": (
        "# 基于 FPGA+RK3568 软硬协同的高性能车载 ADAS 系统\n\n"
        "2026 全国大学生嵌入式芯片与系统设计竞赛——紫光同创杯选题三参赛工程源码包。\n"
    ),
    "BUILD.md": (
        "# 工程构建说明\n\n"
        "详见 docs/submit/BUILD.md。\n"
    ),
    "DEPLOY.md": (
        "# 系统部署说明\n\n"
        "详见 docs/submit/DEPLOY.md。\n"
    ),
    "THIRD_PARTY.md": (
        "# 第三方开源组件说明\n\n"
        "详见 docs/submit/THIRD_PARTY.md。\n"
    ),
}


def is_elf_executable(file_path):
    """
    判断是否为 ELF 可执行文件：无扩展名且 >8 KB 且前 4 字节为 \x7fELF
    """
    if not os.path.isfile(file_path):
        return False
    _, ext = os.path.splitext(file_path)
    if ext != "":
        return False
    try:
        if os.path.getsize(file_path) > 8192:
            with open(file_path, "rb") as f:
                header = f.read(4)
                if header == b"\x7fELF":
                    return True
    except Exception:
        pass
    return False


def is_excluded(full_path, repo_root):
    """
    全局排除规则：
    任何 .bak*、.exe、.pdb、.o、.a、ELF 可执行文件、__pycache__、.git、tmp_*
    """
    try:
        rel_path = os.path.relpath(full_path, repo_root).replace("\\", "/")
    except ValueError:
        rel_path = full_path.replace("\\", "/")

    parts = rel_path.split("/")
    for p in parts:
        if p == "__pycache__" or p == ".git" or p.startswith("tmp_"):
            return True
        if ".bak" in p:
            return True
    # 大体积测试数据不进源码包（npu_det 的 host_test/data 约 166 MB）
    if "host_test/data" in rel_path:
        return True
    if rel_path.startswith("tools/npu_det/host_test/data"):
        return True

    base = os.path.basename(full_path)
    if base.lower().endswith((".exe", ".pdb", ".o", ".a")):
        return True

    if is_elf_executable(full_path):
        print(f"Skipping ELF executable: {rel_path}")
        return True

    return False


def scan_secrets(entries, memory_files):
    """
    安全扫描：对将要打包的文本文件 grep 敏感词，命中打印警告但不终止
    """
    # 扫描磁盘文件
    for arc_name, full_path in sorted(entries.items()):
        base = os.path.basename(full_path)
        _, ext = os.path.splitext(base)
        if ext.lower() not in TEXT_EXTENSIONS and base != "Makefile":
            continue
        try:
            with open(full_path, "r", encoding="utf-8", errors="ignore") as f:
                for line_no, line in enumerate(f, 1):
                    if SECRET_PATTERN.search(line):
                        print(f"WARN secret-like: {arc_name}:{line_no}")
        except Exception:
            pass

    # 扫描内存注入文件
    for arc_name, content in sorted(memory_files.items()):
        for line_no, line in enumerate(content.splitlines(), 1):
            if SECRET_PATTERN.search(line):
                print(f"WARN secret-like: {arc_name}:{line_no}")


def collect_whitelist_files(repo_root, with_assets):
    """
    白名单收集逻辑，不存在则报错退出 3（除非标为 optional）
    """
    entries = {}

    def fail_missing(path_desc):
        sys.stderr.write(f"ERROR [Exit 3]: Required whitelist path does not exist: {path_desc}\n")
        sys.exit(3)

    def add_single_file(rel_or_abs, arc_name, optional=False):
        abs_p = rel_or_abs if os.path.isabs(rel_or_abs) else os.path.join(repo_root, rel_or_abs)
        if not os.path.exists(abs_p):
            if optional:
                return
            fail_missing(rel_or_abs)
        if is_excluded(abs_p, repo_root):
            return
        entries[arc_name.replace("\\", "/")] = os.path.abspath(abs_p)

    def add_directory(rel_dir, filter_fn=None, optional=False, base_arc=None):
        abs_d = rel_dir if os.path.isabs(rel_dir) else os.path.join(repo_root, rel_dir)
        if not os.path.exists(abs_d):
            if optional:
                return
            fail_missing(rel_dir)
        count = 0
        for root, dirs, files in os.walk(abs_d):
            for f in files:
                full = os.path.join(root, f)
                if is_excluded(full, repo_root):
                    continue
                if filter_fn and not filter_fn(f, full):
                    continue
                rel = os.path.relpath(full, repo_root if base_arc is None else abs_d)
                arc = rel if base_arc is None else os.path.join(base_arc, rel)
                entries[arc.replace("\\", "/")] = os.path.abspath(full)
                count += 1
        if count == 0 and not optional:
            fail_missing(f"{rel_dir} (directory contains no matching files)")

    # 1. FPGA
    add_directory("fpga/src", filter_fn=lambda f, p: f.lower().endswith((".v", ".sv", ".vh")))
    for pnr_f in [
        "fpga/pnr/build_cam11.pds",
        "fpga/pnr/build_cam11.tcl",
        "fpga/pnr/build_cam11_s1.pds",
        "fpga/pnr/pango_pcie_top.fdc",
    ]:
        add_single_file(pnr_f, pnr_f)
    add_directory("fpga/ip")
    add_directory("fpga/sim")
    add_directory("fpga/ref_hdmi", filter_fn=lambda f, p: f.lower().endswith(".v"))
    add_directory(
        "fpga/linux/driver",
        filter_fn=lambda f, p: f == "Makefile" or f.lower().endswith((".c", ".h")),
        optional=True,
    )

    # 2. RK3568
    add_directory("tools/usb_feed")
    add_directory(
        "tools/menu",
        filter_fn=lambda f, p: f.lower().endswith((".c", ".h", ".sh", ".py")),
    )
    add_directory("tools/adas")
    add_directory("tools/npu_det")
    for rk_tool in [
        "tools/rk_build.sh",
        "tools/rk_push.py",
        "tools/rk_ssh.py",
        "tools/rk_get.py",
        "tools/rk_put.py",
    ]:
        add_single_file(rk_tool, rk_tool)

    # 3. 算法参考
    add_directory("tools/lane_fpga")
    add_directory("tools/zebra_fpga")
    add_directory(
        "tools/ref_algo",
        filter_fn=lambda f, p: f.lower().endswith((".py", ".json", ".md")),
    )

    # 4. 模型
    for model_f in [
        "models/npu/b5_v6n_band.rknn",
        "models/npu/b5_v6n_band.onnx.json",
        "models/npu/b6_v6n_v3w.rknn",
        "models/npu/b6_v6n_v3w.onnx.json",
    ]:
        add_single_file(model_f, model_f)

    # 5. 文档
    add_single_file("docs/技术文档_草稿.md", "docs/技术文档_草稿.md")
    add_single_file("docs/技术文档_大纲.md", "docs/技术文档_大纲.md", optional=True)
    add_single_file("docs/技术文档_最终稿.md", "docs/技术文档_最终稿.md", optional=True)
    add_single_file("docs/技术文档_最终稿.docx", "docs/技术文档_最终稿.docx", optional=True)
    add_single_file("docs/技术文档_最终稿.pdf", "docs/技术文档_最终稿.pdf", optional=True)
    add_single_file("docs/演示视频_分镜.md", "docs/演示视频_分镜.md", optional=True)
    add_single_file("docs/附录A_寄存器映射.md", "docs/附录A_寄存器映射.md", optional=True)
    add_single_file("docs/附录B_验证复现.md", "docs/附录B_验证复现.md", optional=True)
    add_single_file("docs/答辩要点_评委问答.md", "docs/答辩要点_评委问答.md", optional=True)
    add_directory("docs/figs", optional=True)
    add_directory("docs/submit", optional=True)

    # 6. 预编译 (--with-assets)
    if with_assets:
        add_single_file("D:/pango_work/quad/out/quad_cam11.sbit", "prebuilt/fpga/quad_cam11.sbit")
        add_single_file("fpga/out/quad_cam10f.sbit", "prebuilt/fpga/quad_cam10f.sbit")
        add_single_file("menu/ui_cjk.bin", "prebuilt/menu/ui_cjk.bin")

        tile_matches = glob.glob(os.path.join(repo_root, "menu", "tile[0-3].*"))
        if not tile_matches:
            fail_missing("menu/tile0-3.*")
        for m in tile_matches:
            add_single_file(m, f"prebuilt/menu/{os.path.basename(m)}")

        sel_matches = glob.glob(os.path.join(repo_root, "menu", "sel[0-3].*"))
        if not sel_matches:
            fail_missing("menu/sel0-3.*")
        for m in sel_matches:
            add_single_file(m, f"prebuilt/menu/{os.path.basename(m)}")

    return entries


def prepare_memory_docs(repo_root):
    """
    包内生成 README.md、BUILD.md、DEPLOY.md、THIRD_PARTY.md，内容从 docs/submit/ 读取；
    不存在则使用内置最小模板并警告。
    """
    docs_to_inject = {}
    doc_names = ["README.md", "BUILD.md", "DEPLOY.md", "THIRD_PARTY.md"]
    for name in doc_names:
        submit_path = os.path.join(repo_root, "docs", "submit", name)
        if os.path.exists(submit_path):
            with open(submit_path, "r", encoding="utf-8") as f:
                docs_to_inject[name] = f.read()
        else:
            print(f"WARN: docs/submit/{name} not found, using builtin template")
            docs_to_inject[name] = BUILTIN_TEMPLATES[name]
    return docs_to_inject


def main():
    parser = argparse.ArgumentParser(description="竞赛源码提交包打包脚本")
    today_str = datetime.date.today().strftime("%Y%m%d")
    default_out = os.path.join("dist", f"nesai2026_src_{today_str}.zip")

    parser.add_argument(
        "--out",
        dest="out",
        default=default_out,
        help=f"Output zip path (default: {default_out})",
    )
    parser.add_argument(
        "--dry-run",
        dest="dry_run",
        action="store_true",
        help="Simulate packaging and print summary without writing zip",
    )
    parser.add_argument(
        "--with-assets",
        dest="with_assets",
        action="store_true",
        default=True,
        help="Include prebuilt bitstreams and menu assets (default: True)",
    )
    parser.add_argument(
        "--no-assets",
        "--without-assets",
        dest="with_assets",
        action="store_false",
        help="Exclude prebuilt bitstreams and menu assets",
    )

    args = parser.parse_args()

    # 定位工程根目录
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)

    # 收集文件与生成内存文档
    entries = collect_whitelist_files(repo_root, args.with_assets)
    memory_docs = prepare_memory_docs(repo_root)

    # 执行安全扫描
    scan_secrets(entries, memory_docs)

    total_files = len(entries) + len(memory_docs)

    if args.dry_run:
        print(f"[dry-run] Total files to be packaged: {total_files}")
        print("[dry-run] First 20 files:")
        all_names = sorted(list(memory_docs.keys()) + list(entries.keys()))
        for item in all_names[:20]:
            print(f"  {item}")
        sys.exit(0)

    # 真实创建 zip
    out_path = args.out
    if not os.path.isabs(out_path):
        out_path = os.path.join(repo_root, out_path)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    with zipfile.ZipFile(out_path, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        # 写入根目录下 4 个自动生成文档
        for doc_name, content in memory_docs.items():
            zf.writestr(doc_name, content)

        # 写入物理收集的文件
        for arc_name, abs_path in sorted(entries.items()):
            zf.write(abs_path, arc_name)

    zip_size = os.path.getsize(out_path)
    size_mb = zip_size / (1024 * 1024)
    rel_out = os.path.relpath(out_path, repo_root).replace("\\", "/")

    print(f"files={total_files} bytes={size_mb:.2f}MB zip={rel_out}")
    sys.exit(0)


if __name__ == "__main__":
    main()
