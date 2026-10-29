#!/bin/sh
set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <0|1|2|3>" >&2
    exit 1
fi

case "$1" in
    0|1|2|3)
        MODE="$1"
        ;;
    *)
        echo "Invalid mode: $1 (must be 0..3)" >&2
        exit 1
        ;;
esac

cd "$(dirname "$0")" || exit 1

D=/userdata/quad
FEED=$D/usb_feed_adas
NPU=$D/b5_v6n_band.rknn
BAR=0xf0204000

# 启动前清理旧进程
pkill -x usb_feed 2>/dev/null || true
pkill -x usb_feed_adas 2>/dev/null || true

# 清 0x850 与文本 RAM (主机写 0x850 前先清除 0x8C0 bit2)
ADDR_8C0=$(printf "0x%X" $((BAR + 0x8C0)))
V8C0=$(devmem "$ADDR_8C0" 32 2>/dev/null || true)
if [ -n "$V8C0" ]; then
    V8C0_NEW=$(printf "0x%X" $((V8C0 & ~4)))
    devmem "$ADDR_8C0" 32 "$V8C0_NEW" 2>/dev/null || true
fi
ADDR_850=$(printf "0x%X" $((BAR + 0x850)))
devmem "$ADDR_850" 32 0 2>/dev/null || true

i=0
while [ "$i" -lt 64 ]; do
    devmem "$(printf "0x%X" $((BAR + 0xC00 + i * 4)))" 32 0 2>/dev/null || true
    i=$((i + 1))
done

# 根据模式后台启动 FEED
set +e
case "$MODE" in
    0)
        "$FEED" --bar1 "$BAR" --dst 960x540 --slot0-rgb565 \
            --video "$D/hd/a_113539.mp4:0:30" \
            --video "$D/hd/b_112454.mp4:1:30" \
            --video "$D/hd/c_113539.mp4:2:30" \
            --video "$D/hd/d_112454.mp4:3:30" \
            --npu "$NPU" --adas /dev/null --frames 18000 &
        ;;
    1)
        "$FEED" --bar1 "$BAR" --dst 960x540 --slot0-rgb565 \
            --video "$D/lane/112507.mp4:0:30" \
            --video "$D/lane/113421.mp4:1:30" \
            --video "$D/lane/113452.mp4:2:30" \
            --video "$D/lane/113343.mp4:3:30" \
            --npu "$NPU" --adas /dev/null --frames 18000 &
        ;;
    2)
        "$FEED" --bar1 "$BAR" --dst 960x540 --slot0-rgb565 \
            --video "$D/hd/a_113539.mp4:0:30" \
            --video "$D/hd/b_112454.mp4:1:30" \
            --video "$D/hd/c_113539.mp4:2:30" \
            --video "$D/hd/d_112454.mp4:3:30" \
            --npu "$NPU" --frames 18000 &
        ;;
    3)
        "$FEED" --bar1 "$BAR" --dst 960x540 --slot0-rgb565 \
            --video "$D/hd3/113539_ped2.mp4:0:30" \
            --video "$D/hd/b_112454.mp4:1:30" \
            --video "$D/lane/113421.mp4:2:30" \
            --video "$D/lane/113452.mp4:3:30" \
            --npu "$NPU" --adas /dev/null --frames 18000 &
        ;;
esac

FEED_PID=$!

# 前台监听按键
./menu_launcher --watch "$FEED_PID" --bar1 "$BAR"

# watch 返回后 kill 子进程、等待、再 pkill
kill "$FEED_PID" 2>/dev/null || true
wait "$FEED_PID" 2>/dev/null || true
pkill -x usb_feed_adas 2>/dev/null || true
pkill -x usb_feed 2>/dev/null || true
