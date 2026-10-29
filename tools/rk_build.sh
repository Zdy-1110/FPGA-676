#!/bin/sh
# rk_build.sh <out> <src.c ...> [额外参数] — 用 Zig 交叉编译 RK3568 aarch64 程序（glibc 固定为板上的 2.36）
#   头文件：third_party/mpp-1.0.1/inc、third_party/rknpu2-1.5.0/include
#   链接库：third_party/rk_sysroot/usr/lib（从板上拷回的 librockchip_mpp / librknnrt / librga）
#   例：sh tools/rk_build.sh tools/rk_hello/hello_mpp_rknn tools/rk_hello/hello_mpp_rknn.c -lrockchip_mpp -lrknnrt
cd /e/Project/nesai2026 || exit 1
export ZIG_GLOBAL_CACHE_DIR=D:/tools/zig-cache ZIG_LOCAL_CACHE_DIR=D:/tools/zig-cache
out=$1; shift
exec /d/tools/zig-x86_64-windows-0.14.1/zig.exe cc -target aarch64-linux-gnu.2.36 -O2 -Wall \
    -I third_party/mpp-1.0.1/inc -I third_party/rknpu2-1.5.0/include \
    -L third_party/rk_sysroot/usr/lib -Wl,--allow-shlib-undefined \
    "$@" -o "$out"
