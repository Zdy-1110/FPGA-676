#!/bin/sh
# disp1_board_test.sh — disp1 上板验证（先运行 fpga_reload.sh D:/pango_work/prog_x2_disp1.tcl）
#   1) 上传 pcie_feed、测试帧、测试视频到 RK 的 /tmp（内存盘，重启即清空）
#   2) regs：魔数 0x83C 应为 0x44535031，0x824 DISP_FRAMES 两次读数应在增加（像素时钟在跑）
#   3) pat：显示器上应看到 8 条竖彩条 + 灰网格 + 移动的白方块
#   4) still：显示 113343 第 5 s 的画面；FB_STAT 应为 slot 0、VIDEO_ACTIVE=1、frame_id=1，DISP_UNDERFLOW 不增加
#   5) stream：gst 硬解 → 管道 → pcie_feed，约 16 fps；打印 fps、NEWFR、UNDERFLOW
#   6) pcie_bench D：DDR 门铃与回读回归（回读现在要经过读口仲裁）
cd /e/Project/nesai2026; export MSYS_NO_PATHCONV=1
H=192.168.3.51; B=f0204000; [ "$SLOT" = p30 ] && B=f4204000   # SLOT=p30：卡插在 P30
put() { py -3 tools/rk_put.py $H "$1" "$2" "${3:-644}" >/dev/null && echo "put $2"; }
put tools/pcie_feed/pcie_feed /tmp/pcie_feed 755
put tools/pcie_bench/pcie_bench /tmp/pcie_bench 755
put video_review/nv12/f113343_5s_s1920.nv12 /tmp/f113343.nv12
put video_review/src/video_20260929_113343.mp4 /tmp/v113343.mp4
echo "===== regs"
py -3 tools/rk_ssh.py $H "/tmp/pcie_feed $B regs; sleep 1; /tmp/pcie_feed $B get 824"
echo "===== pat (look at the monitor: colour bars)"
py -3 tools/rk_ssh.py $H "/tmp/pcie_feed $B pat | head -3"
sleep 5
echo "===== still (look at the monitor: 113343 @ 5 s)"
py -3 tools/rk_ssh.py $H "/tmp/pcie_feed $B still /tmp/f113343.nv12 1920"
sleep 5
echo "===== stream via gst pipe (stride 2304)"
py -3 tools/rk_ssh.py $H "gst-launch-1.0 -q filesrc location=/tmp/v113343.mp4 ! qtdemux name=d d.video_0 ! queue ! h265parse ! mppvideodec format=NV12 ! fdsink fd=1 sync=false 2>/tmp/gst_err.txt | /tmp/pcie_feed $B stream - 2304; head -c 300 /tmp/gst_err.txt; /tmp/pcie_feed $B regs | head -14"
echo "===== pcie_bench D regression"
py -3 tools/rk_ssh.py $H "/tmp/pcie_bench $B 1 D 2>&1 | tail -12"
