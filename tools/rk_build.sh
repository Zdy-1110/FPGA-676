#!/bin/sh
# rk_build.sh <out> <src.c ...> [额外参数] — 用 Zig 交叉编译 RK3568 aarch64 程序（glibc 固定为板上的 2.36）
#   头文件：third_party/mpp-1.0.1/inc、third_party/rknpu2-1.5.0/include
#   链接库：third_party/rk_sysroot/usr/lib（从板上拷回的 librockchip_mpp / librknnrt / librga）
#   例：sh tools/rk_build.sh tools/rk_hello/hello_mpp_rknn tools/rk_hello/hello_mpp_rknn.c -lrockchip_mpp -lrknnrt
#   环境变量：ZIG 指定 zig 可执行文件（默认在 PATH 中查找 zig），ZIG_CACHE 指定编译缓存目录
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$ROOT" || exit 1

ZIG=${ZIG:-zig}
if ! command -v "$ZIG" >/dev/null 2>&1; then
    for cand in /d/tools/zig*/zig.exe "$ROOT"/zig*/zig.exe "$ROOT/zig/zig"; do
        [ -x "$cand" ] && ZIG=$cand && break
    done
fi
if ! command -v "$ZIG" >/dev/null 2>&1 && [ ! -x "$ZIG" ]; then
    echo "zig not found: set ZIG=/path/to/zig" >&2
    exit 1
fi
ZIG_CACHE=${ZIG_CACHE:-${TMPDIR:-/tmp}/zig-cache}
export ZIG_GLOBAL_CACHE_DIR="$ZIG_CACHE" ZIG_LOCAL_CACHE_DIR="$ZIG_CACHE"
out=$1; shift
if [ "$out" = "tools/usb_feed/usb_feed" ] && [ $# -eq 0 ]; then
    set -- tools/usb_feed/usb_feed.c tools/usb_feed/usb_night.c tools/usb_feed/fcam_rb_lib.c tools/usb_feed/vdec_mpp.c tools/usb_feed/quad_npu.c tools/usb_feed/quad_sched.c tools/usb_feed/adas.c tools/usb_feed/lane_cls.c tools/usb_feed/nav.c tools/adas/tl_det.c tools/npu_det/npu_post.c -I tools/npu_det -I tools/adas -I third_party/librga-1.9.1/include -lrockchip_mpp third_party/rk_sysroot/usr/lib/librga.so.2.1.0 -lrknnrt -lpthread -lm -std=gnu99
fi
exec "$ZIG" cc -target aarch64-linux-gnu.2.36 -O2 -Wall \
    -I third_party/mpp-1.0.1/inc -I third_party/rknpu2-1.5.0/include \
    -I tools/adas -I tools/npu_det -I third_party/librga-1.9.1/include \
    -L third_party/rk_sysroot/usr/lib -Wl,--allow-shlib-undefined \
    "$@" -o "$out"
