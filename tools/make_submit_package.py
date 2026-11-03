#!/usr/bin/env python3
"""
make_submit_package.py - 竞赛源码提交包打包脚本 (Python 3 标准库)

Usage:
    python tools/make_submit_package.py [--out PATH] [--dry-run] [--with-assets | --without-assets]
    Default output is dist/nesai2026_src_{YYYYMMDD}.rar.
"""

import argparse
import datetime
import glob
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

SECRET_KEYWORDS = ["password", "passwd", "token", "api_key", "secret"]
SECRET_PATTERN = re.compile(r"\b(" + "|".join(SECRET_KEYWORDS) + r")\b", re.IGNORECASE)

TEXT_EXTENSIONS = {
    ".c", ".h", ".v", ".sv", ".vh", ".py", ".sh", ".json", ".md",
    ".tcl", ".fdc", ".pds", ".txt", ".idf", ".csv", ".yaml", ".yml",
    ".toml", ".ini", ".conf", ".cfg", ".ps1"
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
        "fpga/pnr/build_cam23.tcl",
        "fpga/pnr/pango_pcie_top.fdc",
    ]:
        add_single_file(pnr_f, pnr_f)
    add_directory("fpga/ip")
    add_directory("fpga/sim")
    add_directory(
        "fpga/sim_night",
        filter_fn=lambda f, p: f.lower().endswith((".v", ".do", ".py", ".md")),
    )
    add_directory(
        "fpga/tools_night",
        filter_fn=lambda f, p: f.lower().endswith((".v", ".do", ".py", ".md")),
    )

    def _sim_filter(f, p):
        if not f.lower().endswith((".v", ".sv", ".do", ".sh", ".py", ".md", ".hex")):
            return False
        parts = p.replace("\\", "/").split("/")
        if "work" in parts:
            return False
        return True

    add_directory("fpga/sim_sccb", filter_fn=_sim_filter)
    add_directory("fpga/sim_zoom", filter_fn=_sim_filter)
    add_directory("fpga/sim_lane_thr", filter_fn=_sim_filter)

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
        filter_fn=lambda f, p: f.lower().endswith((".c", ".h", ".sh", ".py", ".md")),
    )
    add_single_file("tools/menu/S99adas_menu", "tools/menu/S99adas_menu")
    add_directory("tools/adas")
    add_directory("tools/npu_det")
    add_directory(
        "tools/ov_sccb",
        filter_fn=lambda f, p: f.lower().endswith((".sh", ".txt", ".py", ".md")),
    )
    add_directory(
        "tools/fcam_rb",
        filter_fn=lambda f, p: f.lower().endswith((".c", ".h", ".py", ".md")),
    )

    def _board_eval_filter(f, p):
        if not f.lower().endswith((".py", ".sh", ".md")):
            return False
        norm = p.replace("\\", "/")
        if "tools/board_eval/out/" in norm:
            return False
        return True

    add_directory("tools/board_eval", filter_fn=_board_eval_filter)
    for rk_tool in [
        "tools/rk_build.sh",
        "tools/rk_push.py",
        "tools/rk_ssh.py",
        "tools/rk_get.py",
        "tools/rk_put.py",
        "tools/rk_diag.py",
        "tools/selftest.py",
        "tools/make_demo_udisk.py",
        "tools/fpga_reload.sh",
        "tools/flash/flash_program_cam23.tcl",
        "tools/flash/prog_cam23.tcl",
    ]:
        add_single_file(rk_tool, rk_tool)
    add_single_file("tools/jtag_run_tcl.ps1", "tools/jtag_run_tcl.ps1", optional=True)

    # 一键构建与便携工程入口（评委换机器后无需改路径）
    add_single_file("tools/build_all.sh", "tools/build_all.sh")
    add_single_file("fpga/pnr/build_portable.tcl", "fpga/pnr/build_portable.tcl")

    # 导航示例 (tools/nav_proto)
    for nav_f in [
        "tools/nav_proto/make_navfile.py",
        "tools/nav_proto/test_nav.c",
        "tools/nav_proto/README.md",
        "tools/nav_proto/nav_detect.py",
    ]:
        add_single_file(nav_f, nav_f)
    for nav_out in sorted(glob.glob(os.path.join(repo_root, "tools/nav_proto/out/*.nav"))):
        rel = os.path.relpath(nav_out, repo_root).replace("\\", "/")
        add_single_file(rel, rel)

    # 夜间评估 (tools/night_eval)
    for ne_py in sorted(glob.glob(os.path.join(repo_root, "tools/night_eval/*.py"))):
        rel = os.path.relpath(ne_py, repo_root).replace("\\", "/")
        add_single_file(rel, rel)
    add_single_file("tools/night_eval/README.md", "tools/night_eval/README.md")
    add_single_file("tools/night_eval/out/luma_stats.csv", "tools/night_eval/out/luma_stats.csv")
    add_single_file("tools/night_eval/out/dark/dark_set.csv", "tools/night_eval/out/dark/dark_set.csv")
    for dark_img in [
        "tools/night_eval/out/dark/day_113539_50.jpg",
        "tools/night_eval/out/dark/day_112739_50.jpg",
        "tools/night_eval/out/dark/night40_113539_50.jpg",
        "tools/night_eval/out/dark/night40_112739_50.jpg",
        "tools/night_eval/out/dark/sim_gamma_night40_113539_50.jpg",
        "tools/night_eval/out/dark/sim_gamma_night40_112739_50.jpg",
    ]:
        add_single_file(dark_img, dark_img)

    # 关键证据日志：保持仓库内原始路径，文档中的 `log/...` 引用可直接对上
    for ev in [
        "log/rk_env/build_cam17.log",
        "log/rk_env/pcie_mrd1_L3_20261018.log",
        "log/rk_env/pcie_fast2_soak_ext_20261018.log",
        "log/npu_freq_20261029.md",
        "log/lane_gl_repro_20261030/repro_board.log",
        "log/lane_gl_repro_20261030/repro_recover40.log",
        "log/board_20261101/cam18_timing.rtr",
        "log/board_20261101/cam18_device_map.dmr",
        "log/board_20261101/nav112739_cam18_samples.txt",
        "log/board_20261101/night_still_cam18_lane_points.txt",
        "log/board_20261101/quad4_cam18_result.txt",
        "log/train_b5_v6n_20261027_030923.log",
    ]:
        add_single_file(ev, ev, optional=True)

    for ev_src, ev_arc in [
        ("D:/pango_work/quad/out/cam23_reports/pango_pcie_dma_top.rtr", "evidence/cam23_timing.rtr"),
        ("D:/pango_work/quad/out/cam23_reports/pango_pcie_dma_top.dmr", "evidence/cam23_resource.dmr"),
        ("D:/pango_work/quad/out/cam23_reports/multiseed_result.csv", "evidence/cam23_multiseed_result.csv"),
    ]:
        add_single_file(ev_src, ev_arc, optional=True)

    # 3. 算法参考
    add_directory("tools/lane_fpga")
    add_directory("tools/zebra_fpga")
    add_directory(
        "tools/ref_algo",
        filter_fn=lambda f, p: f.lower().endswith((".py", ".json", ".md")),
    )

    # 3b. 模型训练/转换脚本与 PCIe 测速工具（完整代码，便于复现与二次开发）
    def _code_filter(f, p):
        return f.lower().endswith((".c", ".h", ".py", ".sh", ".md", ".json", ".yaml", ".yml", ".csv"))

    add_directory("tools/npu_train", filter_fn=_code_filter)
    add_directory("tools/npu_convert", filter_fn=_code_filter)
    add_directory("tools/pcie_bench", filter_fn=_code_filter, optional=True)

    # 3c. 全部仿真工程源码（去掉 work/ 编译产物）
    for sim_dir in [
        "fpga/sim", "fpga/sim_ddr", "fpga/sim_disp", "fpga/sim_ms72",
        "fpga/sim_lane_thr", "fpga/sim_sccb", "fpga/sim_zoom", "fpga/sim_night",
        "fpga/sim_lane_thr_par",
    ]:
        add_directory(sim_dir, filter_fn=_sim_filter, optional=True)

    # 3d. 第三方构建依赖（交叉编译必需，评委无需另行下载）
    for tp_dir in ["third_party/mpp-1.0.1", "third_party/rknpu2-1.5.0", "third_party/librga-1.9.1"]:
        add_directory(tp_dir, optional=True)
    add_directory(
        "third_party/rk_sysroot/usr/lib",
        filter_fn=lambda f, p: ".so" in f.lower(),
        optional=True,
    )
    add_single_file("third_party/DOWNLOADS_20261026.md", "third_party/DOWNLOADS_20261026.md", optional=True)

    # 4. 模型
    for model_f in [
        "models/npu/b5_v6n_band.rknn",
        "models/npu/b5_v6n_band.onnx.json",
        "models/npu/b6_v6n_v3w.rknn",
        "models/npu/b6_v6n_v3w.onnx.json",
    ]:
        add_single_file(model_f, model_f)

    # 5. 构建/部署说明（官方"上传全部代码"只要求代码：技术报告、附录、插图等文档不入包）
    add_directory("docs/submit", optional=True)

    # 6. 预编译 (--with-assets)
    if with_assets:
        add_single_file("D:/pango_work/quad/out/quad_cam23.sbit", "prebuilt/fpga/quad_cam23.sbit")
        add_single_file("D:/pango_work/quad/out/quad_cam23.sfc", "prebuilt/fpga/quad_cam23.sfc")
        add_single_file("menu/ui_cjk.bin", "prebuilt/menu/ui_cjk.bin")

        menu_assets = [
            "menu/tile0.rgb565",
            "menu/tile1.nv12",
            "menu/tile2.nv12",
            "menu/tile3.nv12",
            "menu/sel0.rgb565",
            "menu/sel1.nv12",
            "menu/sel2.nv12",
            "menu/sel3.nv12",
        ]
        for m in menu_assets:
            add_single_file(m, f"prebuilt/menu/{os.path.basename(m)}")

    return entries


def prepare_memory_docs(repo_root):
    """
    包内生成 README.md、BUILD.md、DEPLOY.md、THIRD_PARTY.md，内容从 docs/submit/ 读取；
    不存在则使用内置最小模板并警告。
    """
    docs_to_inject = {}
    doc_names = ["README.md", "BUILD.md", "DEPLOY.md", "PORTING.md", "THIRD_PARTY.md"]
    for name in doc_names:
        submit_path = os.path.join(repo_root, "docs", "submit", name)
        if os.path.exists(submit_path):
            with open(submit_path, "r", encoding="utf-8") as f:
                docs_to_inject[name] = f.read()
        else:
            print(f"WARN: docs/submit/{name} not found, using builtin template")
            docs_to_inject[name] = BUILTIN_TEMPLATES[name]
    return docs_to_inject


def generate_manifest_content(entries):
    """
    生成 MANIFEST.txt 内容（路径/大小/SHA256）
    """
    manifest = ["# nesai2026 source package manifest", "# path\tsize_bytes\tsha256"]
    for arc_name, abs_path in sorted(entries.items()):
        h = hashlib.sha256()
        with open(abs_path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        manifest.append(f"{arc_name}\t{os.path.getsize(abs_path)}\t{h.hexdigest()}")
    return "\n".join(manifest) + "\n"


def find_rar_executable():
    """
    按顺序查找 rar 可执行文件
    """
    rar = shutil.which("rar")
    if rar:
        return rar
    candidates = [
        r"C:\Program Files\WinRAR\Rar.exe",
        r"C:\Program Files (x86)\WinRAR\Rar.exe",
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None


def main():
    parser = argparse.ArgumentParser(description="竞赛源码提交包打包脚本")
    today_str = datetime.date.today().strftime("%Y%m%d")
    default_out = os.path.join("dist", f"nesai2026_src_{today_str}.rar")

    parser.add_argument(
        "--out",
        dest="out",
        default=default_out,
        help=f"Output archive path (default: {default_out})",
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

    # 真实创建压缩包
    out_path = args.out
    if not os.path.isabs(out_path):
        out_path = os.path.join(repo_root, out_path)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    manifest_text = generate_manifest_content(entries)
    lower_out = out_path.lower()

    if lower_out.endswith(".zip"):
        with zipfile.ZipFile(out_path, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
            for doc_name, content in memory_docs.items():
                zf.writestr(doc_name, content)
            for arc_name, abs_path in sorted(entries.items()):
                zf.write(abs_path, arc_name)
            zf.writestr("MANIFEST.txt", manifest_text)
    elif lower_out.endswith(".rar"):
        staging = tempfile.mkdtemp()
        try:
            for arc_name, abs_path in sorted(entries.items()):
                target_dest = os.path.join(staging, arc_name)
                os.makedirs(os.path.dirname(target_dest), exist_ok=True)
                shutil.copy2(abs_path, target_dest)

            for doc_name, content in memory_docs.items():
                target_dest = os.path.join(staging, doc_name)
                os.makedirs(os.path.dirname(target_dest), exist_ok=True)
                with open(target_dest, "w", encoding="utf-8") as f:
                    f.write(content)

            manifest_path = os.path.join(staging, "MANIFEST.txt")
            with open(manifest_path, "w", encoding="utf-8") as f:
                f.write(manifest_text)

            rar_bin = find_rar_executable()
            if not rar_bin:
                sys.stderr.write("ERROR [Exit 4]: rar executable not found\n")
                sys.exit(4)

            if os.path.exists(out_path):
                os.remove(out_path)

            cmd = [rar_bin, "a", "-r", "-m5", "-ep1", "-idq", "-y", out_path, os.path.join(staging, "*")]
            ret = subprocess.call(cmd)
            if ret != 0:
                sys.stderr.write(f"ERROR [Exit 5]: rar command failed with return code {ret}\n")
                sys.exit(5)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
    else:
        sys.stderr.write(f"ERROR [Exit 2]: Unsupported archive extension: {out_path}\n")
        sys.exit(2)

    archive_size = os.path.getsize(out_path)
    size_mb = archive_size / (1024 * 1024)
    rel_out = os.path.relpath(out_path, repo_root).replace("\\", "/")

    print(f"files={total_files} bytes={size_mb:.2f}MB archive={rel_out}")
    sys.exit(0)


if __name__ == "__main__":
    main()
