#!/bin/sh
# board_npu.sh [选项...] — PC 上运行：自动化 RK3568 NPU 检测程序板上测试与基准测速。
#   用法 1 (默认模式检测送帧): board_npu.sh [npu_det 选项...]
#   用法 2 (改走 rknn_outputs_get): board_npu.sh --out-get [npu_det 选项...]
#   用法 3 (测速对比):         board_npu.sh --bench
#   用法 4 (同一视频对比输出模式): board_npu.sh --compare-out-zc [npu_det 选项...]
#
# 输出模式说明：
#   - 默认模式：rknn_create_mem + rknn_set_io_mem 零拷贝输出（板上验证与 get 逐框一致且更快）；
#   - --out-get：改用 rknn_outputs_get(want_float=0) + rknn_outputs_release，保证 CPU 缓存一致性。
#
# 环境变量 MODEL：模型名（不含 .rknn），默认 b3f_v8n_band_i8；
#   跑 B2f 等旧模型测速对比时：MODEL=<旧模型名> board_npu.sh --bench
#
# 自动识别 FPGA 在 P29 (BAR1 f0204000) 还是 P30 (f4204000)，使能 EP 与 MPS 256；
# 远程执行并将日志、CSV 与 JSON 保存至 log/npu_det/ 带时间戳的文件中。
cd /e/Project/nesai2026 || exit 1; export MSYS_NO_PATHCONV=1
H=192.168.3.51
M=${MODEL:-b3f_v8n_band_i8}
mkdir -p log/npu_det
TS=$(date +%Y%m%d_%H%M%S)_$M
echo "MODEL=$M"

# 1. 自动识别 PCIe EP 并配置
S=$(py -3 tools/rk_ssh.py $H 'for e in 0002:21:00.0 0000:01:00.0; do E=/sys/bus/pci/devices/$e; [ -e $E ] || continue; echo 1 > $E/enable; printf "\006" | dd of=$E/config bs=1 seek=4 count=1 conv=notrunc 2>/dev/null; [ $e = 0002:21:00.0 ] && for d in 0002:20:00.0 $e; do printf "\060" | dd of=/sys/bus/pci/devices/$d/config bs=1 seek=120 count=1 conv=notrunc 2>/dev/null; done; echo "SLOT_EP $e"; break; done' 2>/dev/null | grep '^SLOT_EP')
case "$S" in
    *0002:21:00.0) B=f0204000 ;;
    *0000:01:00.0) B=f4204000 ;;
    *) echo "RK 上没有 FPGA 设备：PCIe 未建链。在板上看 dmesg | grep 'PCIe Link'"; exit 2 ;;
esac
echo "FPGA EP ${S#SLOT_EP } -> BAR1 $B (EP enabled)"

put() { py -3 tools/rk_put.py $H "$1" "$2" "${3:-644}" >/dev/null && echo "put $2"; }
get() { py -3 tools/rk_get.py $H "$1" "$2" >/dev/null && echo "get $1 -> $2"; }

# 2. 模式分支 1：测速模式 (--bench)
if [ "$1" = "--bench" ]; then
    shift
    echo "=== Running NPU Benchmark Mode (npu_bench) ==="
    put tools/npu_det/npu_bench /tmp/npu_bench 755
    put models/npu/$M.rknn /tmp/$M.rknn 644
    put models/npu/bench_input_960x320.rgb /tmp/bench_input_960x320.rgb 644

    echo "Running normal mode (100 iters)..."
    py -3 tools/rk_ssh.py $H "/tmp/npu_bench /tmp/$M.rknn /tmp/bench_input_960x320.rgb --iters 100 --json /tmp/bench_normal.json > /tmp/bench_normal.log 2>&1"
    get /tmp/bench_normal.log log/npu_det/${TS}_bench_normal.log
    get /tmp/bench_normal.json log/npu_det/${TS}_bench_normal.json
    cat log/npu_det/${TS}_bench_normal.log

    echo "Running zero-copy mode (100 iters)..."
    py -3 tools/rk_ssh.py $H "/tmp/npu_bench /tmp/$M.rknn /tmp/bench_input_960x320.rgb --iters 100 --zero-copy --json /tmp/bench_zc.json > /tmp/bench_zc.log 2>&1"
    get /tmp/bench_zc.log log/npu_det/${TS}_bench_zc.log
    get /tmp/bench_zc.json log/npu_det/${TS}_bench_zc.json
    cat log/npu_det/${TS}_bench_zc.log

    echo "=== NPU Benchmark Complete. Logs saved to log/npu_det/${TS}_bench_* ==="
    exit 0
fi

# 3. 模式分支 2：同一视频对比 --out-get vs --out-zc 模式 (--compare-out-zc)
if [ "$1" = "--compare-out-zc" ]; then
    shift
    echo "=== Running Output Mode Comparison (--compare-out-zc) ==="
    put tools/npu_det/npu_det /tmp/npu_det 755
    put models/npu/$M.rknn /tmp/$M.rknn 644
    py -3 tools/rk_ssh.py $H "[ -f /tmp/v113343.mp4 ] && echo HAVE_MP4" 2>/dev/null | grep -q '^HAVE_MP4' || put video_review/src/video_20260929_113343.mp4 /tmp/v113343.mp4

    # 准备执行脚本
    py -3 tools/rk_ssh.py $H 'cat << "EOF" > /tmp/run_npu.sh
#!/bin/sh
B=$1; F=$2; shift 2
if gst-discoverer-1.0 "$F" 2>/dev/null | grep -qi "H.264"; then
    P="h264parse config-interval=-1 ! video/x-h264,stream-format=byte-stream,alignment=au"; C="--codec h264"
else
    P="h265parse config-interval=-1 ! video/x-h265,stream-format=byte-stream,alignment=au"; C="--codec hevc"
fi
gst-launch-1.0 -q filesrc location="$F" ! qtdemux ! $P ! fdsink fd=1 2>/tmp/run_npu_gst.txt | /tmp/npu_det "$B" - $C --csv /tmp/npu_det.csv "$@"
EOF
chmod +x /tmp/run_npu.sh' 2>/dev/null

    echo "1/2 Running Run A: rknn_outputs_get (--out-get)..."
    py -3 tools/rk_ssh.py $H "rm -f /tmp/npu_det.csv; sh /tmp/run_npu.sh $B /tmp/v113343.mp4 --model /tmp/$M.rknn --out-get $*; echo exit=\$?" 2>&1 | tee log/npu_det/${TS}_run_default.log
    get /tmp/npu_det.csv log/npu_det/${TS}_det_default.csv

    echo "2/2 Running Run B: Zero-Copy output mode (--out-zc)..."
    py -3 tools/rk_ssh.py $H "rm -f /tmp/npu_det.csv; sh /tmp/run_npu.sh $B /tmp/v113343.mp4 --model /tmp/$M.rknn --out-zc $*; echo exit=\$?" 2>&1 | tee log/npu_det/${TS}_run_out_zc.log
    get /tmp/npu_det.csv log/npu_det/${TS}_det_out_zc.csv

    echo "=== Comparison Complete ==="
    echo "Default mode CSV : log/npu_det/${TS}_det_default.csv"
    echo "Out-ZC mode CSV  : log/npu_det/${TS}_det_out_zc.csv"
    exit 0
fi

# 4. 默认检测送帧模式
echo "=== Running NPU Detection & Video Feeder Mode (npu_det) ==="
put tools/npu_det/npu_det /tmp/npu_det 755
put models/npu/$M.rknn /tmp/$M.rknn 644

# 准备测试视频
py -3 tools/rk_ssh.py $H "[ -f /tmp/v113343.mp4 ] && echo HAVE_MP4" 2>/dev/null | grep -q '^HAVE_MP4' || put video_review/src/video_20260929_113343.mp4 /tmp/v113343.mp4

# 在板上生成执行管道脚本
py -3 tools/rk_ssh.py $H 'cat << "EOF" > /tmp/run_npu.sh
#!/bin/sh
B=$1; F=$2; shift 2
if gst-discoverer-1.0 "$F" 2>/dev/null | grep -qi "H.264"; then
    P="h264parse config-interval=-1 ! video/x-h264,stream-format=byte-stream,alignment=au"; C="--codec h264"
else
    P="h265parse config-interval=-1 ! video/x-h265,stream-format=byte-stream,alignment=au"; C="--codec hevc"
fi
gst-launch-1.0 -q filesrc location="$F" ! qtdemux ! $P ! fdsink fd=1 2>/tmp/run_npu_gst.txt | /tmp/npu_det "$B" - $C --csv /tmp/npu_det.csv "$@"
EOF
chmod +x /tmp/run_npu.sh' 2>/dev/null

echo "Starting remote npu_det pipeline..."
py -3 tools/rk_ssh.py $H "rm -f /tmp/npu_det.csv; sh /tmp/run_npu.sh $B /tmp/v113343.mp4 --model /tmp/$M.rknn $*; echo exit=\$?; head -c 400 /tmp/run_npu_gst.txt" 2>&1 | tee log/npu_det/${TS}_npu_det.log

# 取回检测 CSV
py -3 tools/rk_ssh.py $H "[ -f /tmp/npu_det.csv ] && echo HAVE_CSV" 2>/dev/null | grep -q '^HAVE_CSV' && get /tmp/npu_det.csv log/npu_det/${TS}_npu_det.csv

echo "=== Run complete. Log: log/npu_det/${TS}_npu_det.log, CSV: log/npu_det/${TS}_npu_det.csv ==="
