#!/bin/sh
# build_all.sh — 一键交叉编译板端全部程序（输出到各源码目录）
#
# 依赖：zig 0.14.1（PATH 中，或用 ZIG=/path/to/zig 指定）
# 依赖：third_party/（随源码包提供：mpp/rknn/librga 头文件与 rk_sysroot 链接库）
#
# 用法：sh tools/build_all.sh
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$ROOT" || exit 1

echo "[1/6] mode_select"
sh tools/rk_build.sh tools/menu/mode_select tools/menu/mode_select.c

echo "[2/6] menu_daemon"
sh tools/rk_build.sh tools/menu/menu_daemon tools/menu/menu_daemon.c -lpthread

echo "[3/6] usb_menu"
sh tools/rk_build.sh tools/menu/usb_menu tools/menu/usb_menu.c -lpthread

echo "[4/6] usb_feed"
sh tools/rk_build.sh tools/usb_feed/usb_feed

echo "[5/6] npu_bench"
sh tools/rk_build.sh tools/npu_det/npu_bench tools/npu_det/npu_bench.c tools/npu_det/npu_post.c \
    -lrknnrt -lm -std=gnu99

echo "[6/6] fcam_rb"
sh tools/rk_build.sh tools/fcam_rb/fcam_rb tools/fcam_rb/fcam_rb.c -lpthread

echo "=== 全部可执行文件已生成 ==="
