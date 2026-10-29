#!/bin/sh
# run_mp4.sh <bar1_hex> <video.mp4> [test_feeder 选项...] — 板上运行：gst 只做 mp4 解封装（HEVC/H.264 → Annex-B），
# 解码、送帧都在 test_feeder 里（MPP 解码进 CMA，门铃送 FPGA）。编码按文件探测，H.264 自动加 --codec h264。
B=$1; F=$2; shift 2
if gst-discoverer-1.0 "$F" 2>/dev/null | grep -qi "H.264"; then
    P="h264parse config-interval=-1 ! video/x-h264,stream-format=byte-stream,alignment=au"; C="--codec h264"
else
    P="h265parse config-interval=-1 ! video/x-h265,stream-format=byte-stream,alignment=au"; C="--codec hevc"
fi
gst-launch-1.0 -q filesrc location="$F" ! qtdemux ! $P ! fdsink fd=1 2>/tmp/run_mp4_gst.txt | /tmp/test_feeder "$B" - $C "$@"
