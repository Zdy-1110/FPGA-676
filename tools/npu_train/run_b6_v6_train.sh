#!/bin/bash
# run_b6_v6_train.sh: Execute YOLOv6n 150-epoch training with GPU power logging
set -e
cd /mnt/e/Project/nesai2026

LOG_DIR="/mnt/e/Project/nesai2026/log"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GPU_LOG="$LOG_DIR/gpu_b6_v6n_${TIMESTAMP}.csv"
TRAIN_LOG="$LOG_DIR/train_b6_v6n_${TIMESTAMP}.log"

echo "timestamp,pstate,temperature.gpu,utilization.gpu,utilization.memory,memory.total,memory.free,memory.used,power.draw" > "$GPU_LOG"

# Launch background power logge
(
    while true; do
        nvidia-smi --query-gpu=timestamp,pstate,temperature.gpu,utilization.gpu,utilization.memory,memory.total,memory.free,memory.used,power.draw \
                   --format=csv,noheader,nounits >> "$GPU_LOG" 2>/dev/null || true
        sleep 5
    done
) &
LOGGER_PID=$!

cleanup() {
    kill $LOGGER_PID 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Starting b6_v6n_v3w training (150 epochs)..."
cd /mnt/e/Project/nesai2026/third_party/yolov6
/home/zdy/miniconda3/envs/yolov6_train/bin/python tools/train.py \
    --data-path data/npu_v3w.yaml \
    --conf-file configs/yolov6n_npu_v3w.py \
    --img-size 960 \
    --batch-size 16 \
    --epochs 150 \
    --device 0 \
    --name b6_v6n_v3w \
    --output-dir /mnt/e/Project/nesai2026/runs/npu_train > "$TRAIN_LOG" 2>&1

echo "YOLOv6n Training finished successfully with exit code 0"
