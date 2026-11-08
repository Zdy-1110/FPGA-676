# 板端 NPU 检测程序设计（N-3）

本文件说明 N-3 各子任务（npu_post 后处理、npu_bench 测速、npu_det 送帧检测）的模块划分、接口、数值要求与验收口径。

## 0 已定事实
- 板端：RK3568，librknnrt 1.5.0，NPU 驱动 0.9.0，librga 2.1.0（API 1.9.3），无编译器；PC 用 `tools/rk_build.sh`（zig cc `aarch64-linux-gnu.2.36`）交叉编译。头文件：`third_party/rknpu2-1.5.0/include`、`third_party/mpp-1.0.1/inc`、`third_party/librga-1.9.1/include`；库：`third_party/rk_sysroot/usr/lib`。
- 模型：`models/npu/b2f_v8n_band_i8.rknn`。输入 1×320×960×3 RGB uint8（NHWC，mean 0 / std 255 已在模型里）。9 个输出，顺序 box_s8、cls_s8、sum_s8、box_s16、cls_s16、sum_s16、box_s32、cls_s32、sum_s32；box 64 通道（4×16 DFL），cls 9 通道（已 sigmoid），sum 1 通道（clamp(Σcls,0,1)）；网格 40×120 / 20×60 / 10×30。
- 后处理参考：`tools/npu_train/rknn_postprocess.py`（`dfl_decode`、`nms(..., mode=...)`）。
- 路面带：原图 1920×1080 的 y∈[360,1000)、全宽，缩小 2 倍到 960×320。映射回原图：x·2，y·2+360。
- 板端 NMS：`pr_split`，即 person(0) 与 rider(1) 之间不互相抑制，其余任意两类之间做跨类抑制；IoU 0.6。
- FPGA（BAR1，`/dev/mem` mmap，物理地址由参数给出；P29 为 0xf0204000、P30 为 0xf4204000，见 `tools/test_feeder/board_test.sh`）：
  - 框寄存器 0x900 + 8·i（i=0..15）：DW0 = {color[31:28], y0[27:16], 4'b0, x0[11:0]}，DW1 = {4'b0, y1[27:16], 4'b0, x1[11:0]}；坐标为 1920×1080 原图像素；color=0 不画。不按帧锁存，所以 32 个 DW 要在一个紧凑循环里一次写完。
  - 文字 RAM 0xC00 + r·64 + c（4 行 × 64 列 ASCII，每 DW 4 个字符，低字节在前），NPU 用第 2 行（0xC80–0xCBF），格式 `NPU xx fps yy ms n=zz`，其余补空格。
- 颜色（3 位）：person 3（黄）、rider 6（品红）、car/bus/truck 5（青）、tricycle 4（蓝）、cone/barrier 7（白）、speed_limit 2（绿）；1（红）保留给风险目标。
- 现有零拷贝送帧程序：`tools/test_feeder/test_feeder.c`（MPP 解码 → CMA 外部缓冲 → pagemap 校验 <4 GB → 门铃 DMA → 30 fps 节拍 → FB_COMMIT）。test_feeder 保持不动。

## 1 模块划分（目录 `tools/npu_det/`）
| 文件 | 内容 | 依赖 |
|---|---|---|
| `npu_post.h/.c` | 纯 C99 后处理库：DFL 解码、阈值、NMS（agnostic/class/pr_split）、坐标映射与截断、类别→颜色、打包 0x900 寄存器字、文字行格式化 | 只依赖 libc/libm（PC 和板端都能编） |
| `npu_bench.c` | 单独测速 | librknnrt |
| `npu_det.c` | 解码送帧 + 最新帧信箱 + NPU 线程 + 输出 | librknnrt、MPP、librga、pthread、npu_post |
| `host_test/` | PC 上对拍后处理的测试程序与脚本 | npu_post |

## 2 npu_post（子任务 N-3a）
- 输入两种形式（同一套逻辑）：
  - INT8 路径（板端默认）：每个输出一个 `int8_t*` + `zp`（int32）+ `scale`（float），布局 NCHW（与 rknn 输出 `RKNN_TENSOR_NCHW` 一致；若板端实际为 NHWC 由调用方转换或提供步长参数，库内用"通道步长、行步长"参数描述布局）。
  - 浮点路径（调试/对拍）：`float*`，布局同上。
- 流程（每个尺度）：
  1. 用 sum 通道快速过滤：INT8 路径把 conf_thres 换算到量化域，并留一个量化步的余量：`q_thr = floor(conf/scale_sum + zp) − 1`，钳到 [-128,127]；sum < q_thr 的格子直接跳过。原因：sum 与 cls 分别量化、各自舍入，量化后的 sum 可能比最大类别分数低约半个到一个步长，不留余量会在阈值附近误丢框。快速过滤只用来提速，取舍以第 2 步的类别分数为准；浮点路径同样留余量（conf − scale_sum，浮点路径 scale_sum 取 1/255）；
  2. 对剩下的格子求 9 类最大分数与类别，分数 < conf_thres 跳过；
  3. DFL：4 条边各 16 个 bin 做 softmax 后求期望，得到 l,t,r,b；框 = ((col+0.5−l)·s, (row+0.5−t)·s, (col+0.5+r)·s, (row+0.5+b)·s)，单位为 960×320 路面带像素；
  4. 候选上限 `MAX_CAND`（默认 1000，按分数保留最高的）。
- NMS：按分数降序贪心；mode = agnostic / class / pr_split（语义与 `rknn_postprocess.nms` 相同）；输出至多 `max_det` 个。
- 输出结构：{cls, score, 路面带坐标 x0,y0,x1,y1（float）}；另提供：
  - `map_to_src()`：×2、+360，然后截断到 [0,1919]×[0,1079]（解码框可能越界约 −20 px，12 位寄存器写负数会绕回）；
  - `pack_box_regs()`：按分数取前 16 个，生成 32 个 DW（未用的 color=0）；
  - `format_npu_line()`：生成 64 字节文字行。
- 默认参数：conf 0.25、iou 0.6、mode pr_split、max_det 300（评估）/ 16（显示）。全部可由调用方设置。
- 数值要求：与 `rknn_postprocess.py` 同输入同参数时，框数一致、类别一致、坐标差 ≤0.01 px、分数差 ≤1e-5（浮点路径）；INT8 路径与"先反量化再走 Python"的结果相同（同样的容差）。

## 3 PC 对拍（子任务 N-3a）
- 在 WSL `rknn15` 环境写 `host_test/dump_outputs.py`：对 73 张验证图（`datasets/npu_v2w/images/val`）各导出：
  - ONNX fp32 的 9 个原始输出（float32 .bin）；
  - RKNN 模拟器 INT8 的 9 个输出（模拟器返回反量化后的 float；每个输出的 scale/zp 由相邻离散值间距反推，并验证反推后 `(q−zp)·scale` 能逐位还原；还原失败则只测浮点路径并注明）。
  - 同时导出 Python 参考结果（`rknn_postprocess` 解码 + nms，mode pr_split / agnostic，conf 0.25、iou 0.6、max_det 300）为 JSON。
- `host_test/test_post.c`：用 x86_64 编译（WSL 里的 gcc/cc，或 `zig cc -target x86_64-linux-gnu`），读 .bin 跑 npu_post，输出 JSON；`host_test/compare.py` 按 §2 容差逐图比对，打印 `ALL MATCH (73 images, N boxes)` 或首批差异。
- 另加针对 `map_to_src` 截断、`pack_box_regs` 位布局（含 color=0 填充、16 框上限、排序）、`format_npu_line` 的单元测试。

## 4 npu_bench（子任务 N-3b）
- 用法：`npu_bench <model.rknn> [input_960x320.rgb] [iters=100] [--zero-copy]`。
- 流程：`rknn_init` → `rknn_query`（打印 SDK/驱动版本、输入输出属性，含每个输出的 fmt、type、zp、scale）→ 普通模式 `rknn_inputs_set` + `rknn_run` + `rknn_outputs_get(want_float=0)` 计时；`--zero-copy` 时用 `rknn_create_mem` 分配输入输出并 `rknn_set_io_mem`。
- 打印 warmup 10 次后 N 次的 avg/min/max（ms），分别给出 run 与 outputs_get 的耗时；读取并打印 `/sys/class/devfreq/*npu*/cur_freq`（读不到就跳过）。
- 若给了输入文件，再跑一次 npu_post（INT8 路径），把检测结果打印出来（用于和 PC 对拍）。
- PC 上生成测速输入：`models/npu/bench_input_960x320.rgb`（取一张验证图，RGB888 原始字节）及其 Python 参考检测结果。

## 5 npu_det（子任务 N-3c）
- 复用 test_feeder.c 的解码送帧主循环（test_feeder 本身不动），增加：
  - 最新帧信箱：解码线程每出一帧，对该帧 MppBuffer 增加引用后放进 1 格信箱（带帧号）；信箱里已有未取的旧帧就先释放旧帧引用再替换。NPU 线程空闲时取走；处理完释放引用。不排队。
  - NPU 线程：
    1. RGA：源 = MPP 帧（NV12，CMA dma-buf fd，按实际 hor_stride/ver_stride），源矩形 (0,360,1920,640)，目标 = 预先在 `/dev/dma_heap/cma` 分配的 960×320 RGB888 缓冲（同样做 <4 GB 校验）；一次 `improcess` 完成裁剪、缩放与颜色转换；
    2. `rknn_create_mem_from_fd` + `rknn_set_io_mem` 零拷贝输入；`rknn_run`；输出 want_float=0（或 rknn_create_mem 输出）；
    3. npu_post（INT8 路径，scale/zp 来自 rknn_query）；
    4. 输出：`pack_box_regs` 后一次写完 0x900–0x97F；每秒更新一次文字行（fps = 1 s 内完成的 NPU 帧数，ms = 单帧 RGA+推理+后处理平均耗时，n = 当前帧框数）；每帧检测追加写 CSV（帧号、单调时钟 ms、cls、score、原图坐标 x0,y0,x1,y1）。
  - 命令行参数：沿用 test_feeder 的参数，另加 `--model`、`--conf`、`--iou`、`--nms {agnostic,class,pr_split}`、`--csv <path>`、`--no-npu`（只送帧，等价 test_feeder）。
  - 退出时：框寄存器全部清 0（color=0），文字行清空格，释放所有缓冲。
- 板上测试脚本 `tools/npu_det/board_npu.sh`：仿照 `tools/test_feeder/board_test.sh`（自动识别 P29/P30、MPS、上传、运行、取回 CSV）。只生成，需在板卡开机后执行。

## 6 验收（PC 端）
- N-3a：host 对拍 ALL MATCH（浮点路径必须；INT8 路径若 scale/zp 反推成功也必须）；单元测试全过；`npu_post.c` 用 `-std=c99 -Wall -Wextra` 在 x86_64 与 aarch64 下都 0 警告。
- N-3b、N-3c：交叉编译 0 错误 0 警告（`-Wall -Wextra`），`file` 显示 aarch64 ELF；`readelf -d` 依赖库只包含板上已有的 librknnrt.so、librockchip_mpp.so.0、librga.so.2、libpthread/libc/libm。
- 板上验收（开机后）：npu_bench 给出 900 MHz 下单帧耗时；npu_det 显示保持 30 fps 不掉帧、NPU ≥15 fps、框位置正确、取回 CSV 与模拟器结果对比。
