# 板端 ADAS 评测工具 (Board Evaluation)

本目录提供板端实测评测闭环工具链，用于统计板端程序对赛题视频的红绿灯、车道线虚实及自车决策准确率。

---

## 1. 板端运行命令模板

### 参数核实说明
经核实 `tools/usb_feed/usb_feed.c`（第 16 行、第 28 行、第 1925 行、第 1963 行）：
- 原生支持 `--file-once`：单遍播放完成后自动退出进程（默认循环播放）。
- 原生支持 `--frames N`：指定解码 N 帧后退出（`0 = forever`）。
因此运行模板直接使用 `--file-once` 即可实现播放结束自动退出。

### 单视频运行模板
```bash
# 创建日志输出目录
mkdir -p /tmp/eval

# 开启 ADAS_EVAL=1，单遍播放视频并输出日志
ADAS_EVAL=1 /userdata/quad/usb_feed \
    --bar1 0xf0204000 \
    --dst 960x540 \
    --slot0-rgb565 \
    --video /userdata/quad/videos/<vid>.mp4:0:30 \
    --adas /dev/null \
    --npu /userdata/quad/b5_v6n_band.rknn \
    --file-once > /tmp/eval/<vid>.log 2>&1
```

### 7 段赛题视频批量评测脚本 (板端运行)
```bash
#!/bin/sh
VIDEOS="112454 112507 112739 113343 113421 113452 113539"
mkdir -p /tmp/eval

for vid in $VIDEOS; do
    echo "===== 开始评测视频 ${vid} ====="
    ADAS_EVAL=1 /userdata/quad/usb_feed \
        --bar1 0xf0204000 \
        --dst 960x540 \
        --slot0-rgb565 \
        --video "/userdata/quad/videos/${vid}.mp4:0:30" \
        --adas /dev/null \
        --npu /userdata/quad/b5_v6n_band.rknn \
        --file-once > "/tmp/eval/${vid}.log" 2>&1
    echo "视频 ${vid} 运行完成，日志已写入 /tmp/eval/${vid}.log"
done
```

---

## 2. PC 端解析与评测命令

从板端将日志拉取到 PC（如存放在 `./logs/` 目录下）：

### 第一步：解析板端日志为 states.csv
```bash
python tools/board_eval/parse_board_log.py ./logs/*.log --out-dir tools/board_eval/out
```
- `--time-offset <秒>`：补偿板端解码与启动滞后（`t_out = t - offset`，默认 0.0）。
- 支持直接输入多个 log 或通配符，自动识别 6 位视频 ID 并输出到 `<out_dir>/<vid>/states.csv`。
- 具备 t 回卷检测：若视频循环播放（t 变小），仅保留第一遍。

### 第二步：执行评测并生成报告
```bash
# 默认模式：直接调用 tools/ref_algo/eval_ref.py 生成用例判决与逐帧准确率报告
python tools/board_eval/run_eval.py \
    --runs-dir tools/board_eval/out \
    --out-md tools/board_eval/out/report.md \
    --out-csv tools/board_eval/out/report.csv

# 或使用 bash 包装脚本
bash tools/board_eval/run_eval.sh --runs-dir tools/board_eval/out

# 独立评测模式（支持 --skip-low 忽略 conf=low 的 GT 区间）：
python tools/board_eval/run_eval.py \
    --runs-dir tools/board_eval/out \
    --skip-low \
    --out-md tools/board_eval/out/report_skip_low.md
```

---

## 3. 日志格式与映射口径

板端 ADAS_EVAL 日志行格式：
```
eval t=<ch0播放秒,%.2f> sig=<L>/<S>/<R> ll=<valid>,<solid> rl=<valid>,<solid> lane=<0|1|2> mov=<0|1> dec=0x<3位hex>
```

字段映射对应关系：
1. **信号灯 `sig=<L>/<S>/<R>`**
   - 依据 `tools/adas/tl_det.h` 中的 `tl_color_t` 枚举：
     - `0` -> `none`
     - `1` -> `red`
     - `2` -> `yellow`
     - `3` -> `green`
2. **车道线 `ll` (左线) / `rl` (右线)**
   - `valid=0` -> `none`
   - `valid=1 & solid=1` -> `white_solid`（实线）
   - `valid=1 & solid=0` -> `white_dashed`（虚线）
3. **自车运动 `mov`**
   - `1` -> `moving`
   - `0` -> `stopped`
4. **循环播放回卷截断**
   - 当检测到当前时间戳 `t < prev_t` 时，判定为视频循环，后续行自动截断丢弃。
