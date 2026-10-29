#!/bin/bash
# run_b4_train.sh: Execute YOLOv8n-ReLU 150-epoch training with GPU power logging
set -e
cd /mnt/e/Project/nesai2026

LOG_DIR="/mnt/e/Project/nesai2026/log"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GPU_LOG="$LOG_DIR/gpu_b4_v8n_relu_${TIMESTAMP}.csv"
TRAIN_LOG="$LOG_DIR/train_b4_v8n_relu_${TIMESTAMP}.log"

echo "timestamp,pstate,temperature.gpu,utilization.gpu,utilization.memory,memory.total,memory.free,memory.used,power.draw" > "$GPU_LOG"

# Launch background power logger
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

echo "Starting b4_v8n_relu_band training..."
export YOLO_CONFIG_DIR=/mnt/e/Project/nesai2026/.yolo_cfg_wsl
export YOLO_AUTOINSTALL=False
export YOLO_OFFLINE=True

/home/zdy/miniconda3/envs/yolov8_train/bin/python tools/npu_train/train_npu.py \
    --data datasets/npu_v2w/data.yaml \
    --weights /mnt/e/Project/Python_Project/yolo/yolov8n.pt \
    --model-yaml tools/npu_train/yolov8n_relu.yaml \
    --hyp tools/npu_train/hyp_v1.yaml \
    --name b4_v8n_relu_band \
    --epochs 150 \
    --batch 16 \
    --device 0 > "$TRAIN_LOG" 2>&1

echo "Training finished successfully with exit code 0"
