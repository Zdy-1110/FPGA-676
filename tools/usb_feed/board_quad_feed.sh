#!/bin/sh
# board_quad_feed.sh [usb_feed 选项...] —— PC 端执行：识别 FPGA EP、上传 usb_feed、
#   以多路模式（--cam 列表）启动四等分送显，并把控制台日志、每路 gst 日志和 CSV
#   回传到 log/usb_feed/<时间戳>_quad_*。
#
# 默认三路（可改 CAMS 环境变量）：
#   --cam /dev/video17:1 --cam /dev/video19:2 --cam /dev/video21:3
#
# 用法：
#   sh tools/usb_feed/board_quad_feed.sh
#   sh tools/usb_feed/board_quad_feed.sh --frames 300
#   CAMS="--cam /dev/video17:1 --cam /dev/video19:2 --cam /dev/video21:3 --cam /dev/video23:0" \
#       sh tools/usb_feed/board_quad_feed.sh --fps 20
#
# 其余参数原样透传给 usb_feed；--bar1 由脚本按识别到的 EP 自动补在最前面（用户再给则以后者为准）。
# 默认补 --dst 960x540 与 --csv /tmp/usb_feed_quad.csv，用户已给同名参数时不再补。
#
# EP 识别：0002:21:00.0 -> BAR1 f0204000（P29）；0000:01:00.0 -> f4204000（P30）。
# 使能 EP（MEM + BUS_MASTER）并把 MPS 设为 256 字节。
cd /e/Project/nesai2026 || exit 1; export MSYS_NO_PATHCONV=1
H=192.168.3.51
mkdir -p log/usb_feed
TS=$(date +%Y%m%d_%H%M%S)
CAMS=${CAMS:---cam /dev/video17:1 --cam /dev/video19:2 --cam /dev/video21:3}

# 1. 自动识别 PCIe EP 并完成使能
S=$(py -3 tools/rk_ssh.py $H 'for e in 0002:21:00.0 0000:01:00.0; do E=/sys/bus/pci/devices/$e; [ -e $E ] || continue; echo 1 > $E/enable; printf "\006" | dd of=$E/config bs=1 seek=4 count=1 conv=notrunc 2>/dev/null; [ $e = 0002:21:00.0 ] && for d in 0002:20:00.0 $e; do printf "\060" | dd of=/sys/bus/pci/devices/$d/config bs=1 seek=120 count=1 conv=notrunc 2>/dev/null; done; echo "SLOT_EP $e"; break; done' 2>/dev/null | grep '^SLOT_EP')
case "$S" in
    *0002:21:00.0) B=f0204000 ;;
    *0000:01:00.0) B=f4204000 ;;
    *) echo "RK 上没有 FPGA 设备，PCIe 可能未枚举（板上试 dmesg | grep 'PCIe Link'）"; exit 2 ;;
esac
echo "FPGA EP ${S#SLOT_EP } -> BAR1 $B (EP enabled, MPS 256)"

put() { py -3 tools/rk_put.py $H "$1" "$2" "${3:-644}" >/dev/null && echo "put $2"; }
get() { py -3 tools/rk_get.py $H "$1" "$2" >/dev/null && echo "get $1 -> $2"; }

# 2. 上传程序
put tools/usb_feed/usb_feed /tmp/usb_feed 755 || exit 3

# 3. 组装远端命令（用户已给的同名参数优先）
DSTOPT="--dst 960x540"
case "$*" in *--dst*) DSTOPT="" ;; esac
CSVOPT="--csv /tmp/usb_feed_quad.csv"
case "$*" in *--csv*) CSVOPT="" ;; esac
GSTOPT="--gst-log /tmp/usb_feed_quad_gst"
case "$*" in *--gst-log*) GSTOPT="" ;; esac

echo "=== Running multi-camera feeder (usb_feed) ==="
echo "cams: $CAMS"
echo "args: --bar1 $B $DSTOPT $CSVOPT $GSTOPT $*"
py -3 tools/rk_ssh.py $H "rm -f /tmp/usb_feed_quad.csv.*.csv /tmp/usb_feed_quad_gst.*.log; /tmp/usb_feed --bar1 $B $DSTOPT $CSVOPT $GSTOPT $CAMS $*; echo exit=\$?" 2>&1 | tee log/usb_feed/${TS}_quad_feed.log

# 4. 回传每路 gst 日志与 CSV（slot 号来自 CAM 列表；文件不存在时跳过）
SLOTS=$(echo "$CAMS" | tr ' ' '\n' | awk -F: '$1 ~ /^\/dev/ {print $2}' | sort -u)
[ -n "$SLOTS" ] || SLOTS="0 1 2 3"
for s in $SLOTS; do
    py -3 tools/rk_ssh.py $H "[ -f /tmp/usb_feed_quad_gst.$s.log ] && echo HAVE_GST" 2>/dev/null | grep -q '^HAVE_GST' \
        && get /tmp/usb_feed_quad_gst.$s.log log/usb_feed/${TS}_quad_gst_slot$s.log
    py -3 tools/rk_ssh.py $H "[ -f /tmp/usb_feed_quad.csv.$s.csv ] && echo HAVE_CSV" 2>/dev/null | grep -q '^HAVE_CSV' \
        && get /tmp/usb_feed_quad.csv.$s.csv log/usb_feed/${TS}_quad_slot$s.csv
done

echo "=== Run complete. Log: log/usb_feed/${TS}_quad_feed.log, per-slot files: log/usb_feed/${TS}_quad_* ==="
