#!/bin/sh
# board_test.sh [test_feeder 选项...] — PC 上运行：上传 test_feeder、run_mp4.sh、113343 测试视频到 RK /tmp，然后 30 fps 播放。
#   20261019：自动识别 FPGA 在 P29（EP 0002:21:00.0，BAR1 f0204000）还是 P30（0000:01:00.0，f4204000），
#   并使能 EP（RK 重启后默认未使能）；两个槽都没有 EP 就说明 PCIe 没建链，直接退出。SLOT 变量已不再需要。
#   P29 上顺带把根端口和 EP 的 MPS 设为 256（DevCtl 低字节 0x30，偏移 120，重启即复位）：门铃 506→770 MB/s，
#   不限速送帧 126→202 fps（20261019 实测）。P30 根端口未验证，不改。
cd /e/Project/nesai2026 || exit 1; export MSYS_NO_PATHCONV=1
H=192.168.3.51
S=$(py -3 tools/rk_ssh.py $H 'for e in 0002:21:00.0 0000:01:00.0; do E=/sys/bus/pci/devices/$e; [ -e $E ] || continue; echo 1 > $E/enable; printf "\006" | dd of=$E/config bs=1 seek=4 count=1 conv=notrunc 2>/dev/null; [ $e = 0002:21:00.0 ] && for d in 0002:20:00.0 $e; do printf "\060" | dd of=/sys/bus/pci/devices/$d/config bs=1 seek=120 count=1 conv=notrunc 2>/dev/null; done; echo "SLOT_EP $e"; break; done' 2>/dev/null | grep '^SLOT_EP')
case "$S" in
    *0002:21:00.0) B=f0204000 ;;
    *0000:01:00.0) B=f4204000 ;;
    *) echo "RK 上没有 FPGA 设备：PCIe 未建链。在板上看 dmesg | grep 'PCIe Link'"; exit 2 ;;
esac
echo "FPGA EP ${S#SLOT_EP } -> BAR1 $B (EP enabled)"
put() { py -3 tools/rk_put.py $H "$1" "$2" "${3:-644}" >/dev/null && echo "put $2"; }
put tools/test_feeder/test_feeder /tmp/test_feeder 755
put tools/test_feeder/run_mp4.sh /tmp/run_mp4.sh 755
py -3 tools/rk_ssh.py $H "[ -f /tmp/v113343.mp4 ] && echo HAVE_MP4" 2>/dev/null | grep -q '^HAVE_MP4' || put video_review/src/video_20260929_113343.mp4 /tmp/v113343.mp4   # rk_ssh 不回传远端退出码
py -3 tools/rk_ssh.py $H "sh /tmp/run_mp4.sh $B /tmp/v113343.mp4 $*; echo exit=\$?; head -c 400 /tmp/run_mp4_gst.txt"
