#!/bin/sh
# board_usb_feed.sh [usb_feed 选项...] —— PC 端执行：识别 FPGA EP、上传 usb_feed、
#   运行 USB 摄像头（MJPEG）-> MPP 解码 -> RGA -> PCIe 送显，并把日志/CSV 回传到
#   log/usb_feed/<时间戳>_*。
#
# 用法：
#   sh tools/usb_feed/board_usb_feed.sh
#       # 默认：/dev/video17，1280x720 -> 1920x1080，slot 2，30fps，一直跑
#   sh tools/usb_feed/board_usb_feed.sh --dev /dev/video21 --frames 300
#   sh tools/usb_feed/board_usb_feed.sh --src 640x480 --dst 1920x1080 --fps 25 --csv /tmp/u.csv
#   sh tools/usb_feed/board_usb_feed.sh --file /tmp/v.mp4:1:30 --dst 960x540
#   sh tools/usb_feed/board_usb_feed.sh --file /tmp/v.mp4:0:30 --slot0-rgb565 --file-once
#   sh tools/usb_feed/board_usb_feed.sh --cam /dev/video17:1 --file /tmp/v.mp4:0 --slot0-rgb565
#
# 命令行参数原样透传给 usb_feed；--bar1 由脚本按识别到的 EP 自动补在最前面，
# 若参数里再给 --bar1，后者（用户给的）生效。默认给 --csv /tmp/usb_feed.csv，
# 若用户自己给了 --csv 则不再补。
#
# 自动识别 FPGA 所在 PCIe 槽：0002:21:00.0 -> BAR1 f0204000（P29）；
# 0000:01:00.0 -> f4204000（P30）。使能 EP（MEM + BUS_MASTER）并把 MPS 设为 256 字节。
cd /e/Project/nesai2026 || exit 1; export MSYS_NO_PATHCONV=1
H=192.168.3.51
mkdir -p log/usb_feed
TS=$(date +%Y%m%d_%H%M%S)

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

# 3. 组装远端命令（--csv 只有用户没给时才补默认值）
CSVOPT="--csv /tmp/usb_feed.csv"
case "$*" in
    *--csv*) CSVOPT="" ;;
esac

echo "=== Running USB camera feeder (usb_feed) ==="
echo "args: --bar1 $B $CSVOPT $*"
py -3 tools/rk_ssh.py $H "rm -f /tmp/usb_feed.csv; /tmp/usb_feed --bar1 $B $CSVOPT $*; echo exit=\$?" 2>&1 | tee log/usb_feed/${TS}_usb_feed.log

# 4. 回传 CSV（若产生）
py -3 tools/rk_ssh.py $H '[ -f /tmp/usb_feed.csv ] && echo HAVE_CSV' 2>/dev/null | grep -q '^HAVE_CSV' && get /tmp/usb_feed.csv log/usb_feed/${TS}_usb_feed.csv

echo "=== Run complete. Log: log/usb_feed/${TS}_usb_feed.log, CSV: log/usb_feed/${TS}_usb_feed.csv ==="
