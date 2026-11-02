#!/bin/sh
# 板端车道线 A/B：同一视频分别用 FPGA 原判定(fpga) 与 RK 桶式判定(bucket) 跑一遍，输出 eval 日志。
# 用法（板上）：sh /tmp/ab_lane.sh
D="/run/media/sda1/紫光同创杯赛题三参考素材"
rm -f /tmp/ab_done
devmem 0xf0204800 32 0x65
devmem 0xf02048c0 32 3
for v in 112507 113343 113452 113539; do
    for m in fpga bucket; do
        ADAS_EVAL=1 ADAS_LANE_CLS=$m /userdata/quad/usb_feed \
            --bar1 0xf0204000 --dst 960x540 --slot0-rgb565 \
            --video "$D/video_20260929_$v.mp4:0:30" \
            --adas /dev/null --file-once > "/tmp/ab_${v}_${m}.log" 2>&1
    done
done
devmem 0xf0204800 32 0x865
devmem 0xf02048c0 32 0
echo DONE > /tmp/ab_done
