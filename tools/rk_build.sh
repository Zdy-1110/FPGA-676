#!/bin/sh
# rk_build.sh <out> <src.c ...> [额外参数] — 用 Zig 交叉编译 RK3568 aarch64 程序（glibc 固定为板上的 2.36）
#   头文件：third_party/mpp-1.0.1/inc、third_party/rknpu2-1.5.0/include
#   链接库：third_party/rk_sysroot/usr/lib（从板上拷回的 librockchip_mpp / librknnrt / librga）
#   例：sh tools/rk_build.sh tools/rk_hello/hello_mpp_rknn tools/rk_hello/hello_mpp_rknn.c -lrockchip_mpp -lrknnrt
cd /e/Project/nesai2026 || exit 1
export ZIG_GLOBAL_CACHE_DIR=D:/tools/zig-cache ZIG_LOCAL_CACHE_DIR=D:/tools/zig-cache
out=$1; shift
if [ "$out" = "tools/usb_feed/usb_feed" ] && [ $# -eq 0 ]; then
    set -- tools/usb_feed/usb_feed.c tools/usb_feed/vdec_mpp.c tools/usb_feed/quad_npu.c tools/usb_feed/quad_sched.c tools/usb_feed/adas.c tools/adas/tl_det.c tools/npu_det/npu_post.c -I tools/npu_det -I tools/adas -I third_party/librga-1.9.1/include -lrockchip_mpp third_party/rk_sysroot/usr/lib/librga.so.2.1.0 -lrknnrt -lpthread -lm -std=gnu99
fi
exec /d/tools/zig-x86_64-windows-0.14.1/zig.exe cc -target aarch64-linux-gnu.2.36 -O2 -Wall \
    -I third_party/mpp-1.0.1/inc -I third_party/rknpu2-1.5.0/include \
    -I tools/adas -I tools/npu_det -I third_party/librga-1.9.1/include \
    -L third_party/rk_sysroot/usr/lib -Wl,--allow-shlib-undefined \
    "$@" -o "$out"
