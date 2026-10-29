# NPU 检测程序开发进展（PROGRESS）

## 子任务 N-3a：纯 C 后处理库 npu_post 与 PC 对拍

- **日期**：2026-10-26
- **设计依据**：`tools/npu_det/DESIGN.md` §0, §2, §3
- **状态**：完成并通过全部验收

### 1. 模块实现清单
- `tools/npu_det/npu_post.h`
  - 纯 C99 接口头文件，定义张量步长布局描述 `npu_tensor_t`、`npu_scale_t`。
  - 支持 FP32 与 INT8 双路径后处理：`npu_post_process_fp32`、`npu_post_process_int8` 及 9 张量便捷包装。
  - 支持 3 种 NMS 模式：`agnostic`、`class`、`pr_split`（person 0 与 rider 1 不互斥）。
  - 支持辅助函数：`npu_map_to_src`（坐标截断至 [0,1919]×[0,1079]）、`npu_pack_box_regs`（前 16 框 32 DW 寄存器字打包，color=0 填充）、`npu_format_npu_line`（64 字节文字行格式化）、`npu_quant_conf_threshold`（含 1 步量化余量的阈值换算）。
- `tools/npu_det/npu_post.c`
  - 核心后处理逻辑：sum 通道快速过滤（INT8 留 1 步余量 `floor(conf/scale+zp)-1`，浮点留 `conf-1/255` 余量）、9 类最大分数计算、DFL softmax 与期望解码、1000 候选上限过滤、贪心 NMS。
  - 无全局状态，线程安全。
- `tools/npu_det/host_test/test_units.c`
  - 单元测试：`map_to_src` 截断、`pack_box_regs` 位布局/分数降序/16 框上限/color=0 填充、`format_npu_line` 64 字节空格填充、`npu_quant_conf_threshold` 量化域换算、sum 通道比类别低 1 步长不丢框测试。
- `tools/npu_det/host_test/dump_outputs.py`
  - 在 WSL `rknn15` 环境运行，导出 73 张验证图的 ONNX FP32 与 RKNN 模拟器 INT8 输出至 `.bin`，反推并验证 scale/zp，导出 4 组 Python 参考 JSON。
- `tools/npu_det/host_test/test_post.c`
  - 纯 C99 驱动，读取 `meta.json` 与 `.bin`，调用 `npu_post` 生成预测 JSON。
- `tools/npu_det/host_test/compare.py`
  - 逐图逐框比对工具，严格按照容差（框数与类别一致、坐标差 ≤0.01 px、分数差 ≤1e-5）进行检验。
- `tools/npu_det/host_test/run_host_test.sh`
  - 一键编译与验收脚本，自动编译测试程序并依次执行单元测试与 4 组对拍。

### 2. INT8 scale/zp 反推与 bit-exact 还原
- 9 个输出张量的 scale 与 zp 反推结果：
  - `box_s8` : `scale = 0.137250423`, `zp = -28`
  - `cls_s8` : `scale = 0.00382087054`, `zp = -128`
  - `sum_s8` : `scale = 0.00392156886`, `zp = -128`
  - `box_s16`: `scale = 0.114720561`, `zp = -9`
  - `cls_s16`: `scale = 0.00387145067`, `zp = -128`
  - `sum_s16`: `scale = 0.00392156886`, `zp = -128`
  - `box_s32`: `scale = 0.100186974`, `zp = -21`
  - `cls_s32`: `scale = 0.00384379923`, `zp = -128`
  - `sum_s32`: `scale = 0.00392156886`, `zp = -128`
- 还原验证结论：全部 73 张图经 `(q - zp) * scale` 反量化后，与模拟器输出浮点值逐 bit 完全一致（Bit-exact True, 最大重构误差 0.0）。

### 3. 验收结果
1. **交叉编译（-std=c99 -Wall -Wextra -O2）**：
   - aarch64-linux-gnu.2.36：0 警告，ELF 正常。
   - x86_64-linux-gnu：0 警告，ELF 正常。
2. **单元测试 (`test_units`)**：退出码 0，5 项测试全过。
3. **4 组对拍结果 (`run_host_test.sh`)**：退出码 0。
   - FP32 + pr_split : ALL MATCH (73 images, 771 boxes, max_coord_err=0.000060, max_score_err=4.999847e-07)
   - FP32 + agnostic : ALL MATCH (73 images, 759 boxes, max_coord_err=0.000060, max_score_err=4.999847e-07)
   - INT8 + pr_split : ALL MATCH (73 images, 734 boxes, max_coord_err=0.000070, max_score_err=4.988136e-07)
   - INT8 + agnostic : ALL MATCH (73 images, 722 boxes, max_coord_err=0.000070, max_score_err=4.988136e-07)

## 子任务 N-3b：单独测速工具 npu_bench 与输入数据准备

- **日期**：2026-10-26
- **设计依据**：`tools/npu_det/DESIGN.md` §0, §4
- **状态**：完成并通过全部验收

### 1. 模块实现清单
- `tools/npu_det/npu_bench.c`
  - 单独测速驱动，实现标准模式（`rknn_inputs_set` + `rknn_run` + `rknn_outputs_get(want_float=0)`）与零拷贝模式（`--zero-copy`：`rknn_create_mem` + `rknn_set_io_mem`）。
  - 支持查询并打印 SDK/驱动版本、输入/输出张量属性（name、dims、fmt、type、qnt_type、zp、scale、size）。
  - 支持读取 `/sys/class/devfreq/*npu*/cur_freq`。
  - 支持 warmup 10 次后 N 次耗时统计（avg/min/max/FPS，CLOCK_MONOTONIC）。
  - 支持若提供输入文件，调用 `npu_post` INT8 路径（conf 0.25, iou 0.6, pr_split, max_det 300）解码并打印路面带与原图坐标，可选 `--json <path>` 导出 host_test 对拍 JSON。
  - 所有 API 返回值均严格检查并统一清理退出。
- `tools/npu_det/host_test/make_bench_input.py`
  - 在 WSL `rknn15` 环境运行，取 `datasets/npu_v2w/images/val` 排序后第 1 张图（经比对与 `meta.json` 中 `img_idx 0` 一致：`video_20260929_113343__video_20260929_113343_t0.00.jpg`）。
  - 导出 RGB888 原始字节到 `models/npu/bench_input_960x320.rgb`（921600 字节）。
  - 复制该图的 INT8 + pr_split Python 参考检测结果（7 个目标框）到 `models/npu/bench_ref_int8_pr_split.json`。

### 2. 验收结果
1. **交叉编译**：
   - 命令：`sh tools/rk_build.sh tools/npu_det/npu_bench tools/npu_det/npu_bench.c tools/npu_det/npu_post.c -lrknnrt -lm -std=gnu99 -Wextra`
   - 退出码：0，0 错误，0 警告。
2. **产物检查**：
   - `file`：`ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), dynamically linked, interpreter /lib/ld-linux-aarch64.so.1`
   - `readelf -d` NEEDED：`librknnrt.so`、`libm.so.6`、`libc.so.6`。
3. **输入与参考数据核对**：
   - `models/npu/bench_input_960x320.rgb` 大小为 921600 字节。
   - `models/npu/bench_ref_int8_pr_split.json` 包含 7 个检测框，与 `host_test/data/ref_rknn_pr_split.json` 中 `img_idx 0` 逐字段完全一致。

## 子任务 N-3c1：解码送帧 + 最新帧信箱 + NPU 线程 RGA 预处理

- **日期**：2026-10-26
- **设计依据**：`tools/npu_det/DESIGN.md` §0, §5
- **代码快照**：`tools/npu_det/snapshots/npu_det_c1.c`
- **状态**：完成并通过全部交叉编译验收

### 1. 修改清单（对照 `tools/test_feeder/test_feeder.c`）
- `npu_det.c` 行 21, 29：引入 `<pthread.h>` 与 `"im2d.h"`。
- `npu_det.c` 行 69–84：扩充 `Options` 结构体，支持 `--no-npu`、`--dump-rgb`、`--dump-at`、`--model`、`--conf`、`--iou`、`--nms`、`--csv`。
- `npu_det.c` 行 88–106：定义 `FrameMailboxItem` 与 `FrameMailbox`（1 格互斥量+条件变量信箱结构）。
- `npu_det.c` 行 133–141, 145–146：信箱、NPU 线程句柄、CMA RGB 缓冲及统计状态全局变量。
- `npu_det.c` 行 179–216：从 `check_phys` 抽象提取通用的 `check_phys_range` 物理连续性与 `<4 GB` pagemap 校验函数。
- `npu_det.c` 行 260–305：`alloc_npu_buffer` 从 CMA 分配 960×320×3 目标缓冲并 `importbuffer_fd` 预导入目标句柄。
- `npu_det.c` 行 435–456：`handle_frame` 在提交送显后、`mpp_frame_deinit` 前执行 `mpp_buffer_inc_ref` 投递信箱（覆盖旧帧先 `mpp_buffer_put`）。
- `npu_det.c` 行 464–555：`npu_thread_func` NPU 工作线程主循环（等待信箱、importbuffer、wrapbuffer、imcheck、improcess、dump、mpp_buffer_put）。
- `npu_det.c` 行 557–602：`print_stat` 与 `print_summary` 扩充输出 NPU 帧数、丢弃帧数、RGA 平均与最大耗时。
- `npu_det.c` 行 604–639：`cleanup` 增加 NPU 线程终止与 join、信箱残留帧引用释放、RGA 目标句柄释放与 CMA munmap/close。
- `npu_det.c` 行 720–735：`usage` 扩充新增选项说明。
- `npu_det.c` 行 747–817：`main` 外部缓冲默认值改 26，解析新参数，初始化信箱并启动 NPU 预处理线程。
- `npu_det.c` 行 881–888：主循环退出后先通知并 join NPU 线程，保证 summary 统计一致性。

### 2. 外部缓冲数量与 CMA 占用估算
- **依据**：1080p HEVC 解码 DPB 最大参考帧为 16 帧，重排序与调度通常需 4~6 帧，解码器基础需求 20~22 帧。`test_feeder` 默认分配 24 帧。引入信箱（最多滞留 1 帧）与 NPU 线程（最多持 1 帧）后，额外占用至多 2 帧，因此将默认外部缓冲从 24 增加到 26 帧（`--ext-bufs 26`）。
- **CMA 占用计算**：
  - 外部缓冲：26 帧 × (2304 × 1088 × 1.5 B) = 26 × 3,759,936 B ≈ 93.23 MiB (97.76 MB)。
  - NPU RGB888 缓冲：960 × 320 × 3 B = 921,600 B = 225 页 ≈ 0.88 MiB (0.92 MB)。
  - 合计 CMA 占用：约 94.11 MiB (98.68 MB)，占板端 CMA 256 MB 总量的 36.7%，剩余 >157 MB，容量充足。

### 3. RGA 调用规范
- **API**：`improcess(src, dst, pat, srect, drect, prect, 0)` 单次完成裁剪 + 缩放 + NV12→RGB888 转换。
- **格式**：源为 `RK_FORMAT_YCbCr_420_SP` (NV12)，目标为 `RK_FORMAT_RGB_888`。
- **步长**：源 `wstride = hor_stride` (2304), `hstride = ver_stride` (1088)；目标 `wstride = 960, hstride = 320`。
- **矩形**：`srect = (0, 360, 1920, 640)`，`drect = (0, 0, 960, 320)`。
- **颜色空间**：显式指定 `src.color_space_mode = IM_YUV_TO_RGB_BT601_LIMIT`（BT.601 limited range / MPEG 范围）。

## 子任务 N-3c2：NPU 线程推理接入 + 后处理 + 寄存器/文字/CSV 输出 + 上板脚本

- **日期**：2026-10-26
- **设计依据**：`tools/npu_det/DESIGN.md` §0, §5
- **状态**：完成并通过全部交叉编译验收

### 1. 模块实现与修改清单
- `tools/npu_det/npu_det.c`
  - 行 31–32：引入 `"rknn_api.h"` 与 `"npu_post.h"`。
  - 行 141–166：新增 RKNN 上下文、I/O 张量属性、9 张量映射、零拷贝内存结构与推理/后处理性能统计全局变量。
  - 行 330–488：新增 `find_output_index` 与 `init_rknn` 函数：读取并初始化 RKNN 模型，查询输入/输出属性；输入尝试使用 `rknn_create_mem_from_fd`（绑定 CMA dma-buf fd 零拷贝），失败则优雅回退至 `rknn_inputs_set`；输出使用 `rknn_create_mem` + `rknn_set_io_mem`；严格校验 NCHW/NHWC 维度并预建步长模板。
  - 行 728–805：在 `npu_thread_func` 中 RGA 处理后接入推理与后处理：执行 `rknn_run`、调用 `npu_post_process_9tensors_int8` INT8 解码、`npu_map_dets_to_src` 坐标映射截断、`npu_pack_box_regs` 打包并在紧凑循环中一次性写入 BAR1 0x900–0x97F（32 个 DW）；支持 `--csv` 格式写出检测结果（无检测框时补写 `-1` 占位行）。
  - 行 818–858：更新 `print_stat` 与 `print_summary`：每秒通过 `npu_format_npu_line` 更新 BAR1 文字 RAM 行 2 (0xC80–0xCBF)，每秒 `fflush(g_csv_fp)`，终端统计输出补充 NPU fps、推理平均耗时、后处理平均耗时与当前框数。
  - 行 860–920：`cleanup` 中确保按正确顺序清理：先 join NPU 线程，然后写 0 清除框寄存器、写空格清除文字 RAM、销毁 RKNN 内存与上下文、关闭 CSV，最后释放 RGA 与 CMA 缓冲，保证硬件与线程不再访问已释放内存。
  - 行 1118–1172：调整 `main` 顺序，先完成 BAR1 寄存器映射与 magic 校验，再初始化 NPU/RKNN 资源并启动工作线程；校验 `--model` 并在非法 NMS 模式时提前报错。
- `tools/npu_det/board_npu.sh`（共 75 行）
  - 仿照 `tools/test_feeder/board_test.sh` 编写自动化测试脚本。
  - 自动识别 P29/P30 槽位 EP 并使能，优化 MPS 256。
  - 支持完整送帧检测流程（上传程序、模型与视频，远程执行并将日志与 CSV 下载至 `log/npu_det/`）。
  - 支持 `--bench` 独立测速模式（上传 `npu_bench`、模型与输入文件，运行普通模式与 `--zero-copy` 模式各 100 次，取回日志与 JSON）。
  - 绝不硬编码密码凭据，遵循只生成不上板原则。

### 2. 验收结果
1. **交叉编译**：
   - 命令：`& 'C:\Program Files\Git\bin\sh.exe' tools/rk_build.sh tools/npu_det/npu_det tools/npu_det/npu_det.c tools/npu_det/npu_post.c -I third_party/librga-1.9.1/include -lrockchip_mpp third_party/rk_sysroot/usr/lib/librga.so.2.1.0 -lrknnrt -lpthread -lm -std=gnu99 -Wextra`
   - 退出码：0，0 错误，0 警告。
2. **产物检查**：
   - `file`：`ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), dynamically linked, interpreter /lib/ld-linux-aarch64.so.1`
   - `readelf -d` NEEDED：`librockchip_mpp.so.1`、`librga.so.2`、`librknnrt.so`、`libm.so.6`、`libc.so.6`。
3. **API 规范确认**：
   - `rknn_api.h` 1.5.0 头文件确认**不包含 `rknn_mem_sync` API**（该 API 为 1.6+ 引入）。为确保 CPU 缓存一致性，将默认输出模式调整为 `rknn_outputs_get` + `rknn_outputs_release`。

### 3. 输出缓存一致性与 RGA 颜色空间修正（2026-10-26 修正）
- **输出模式重构**：
  - 默认模式：采用 `rknn_outputs_get(want_float=0)` 获取 NPU 输出缓冲，后处理完成后立即调用 `rknn_outputs_release` 释放，严格保证 CPU 缓存一致性与成对释放。
  - `--out-zc` 选项：保留 `rknn_create_mem` + `rknn_set_io_mem` 零拷贝输出路径。
  - 启动时显式打印当前输出模式；每秒统计行单列 `get_avg` 耗时。
- **RGA 颜色转换**：
  - 将 `src.color_space_mode` 与 `dst.color_space_mode` 均显式配置为 `IM_YUV_TO_RGB_BT601_LIMIT`。
- **上板脚本与编译**：
  - `tools/npu_det/board_npu.sh` 扩充 `--out-zc` 与 `--compare-out-zc`（同一视频对比默认与 `--out-zc` 模式）用法与说明。
  - 交叉编译 0 错误 0 警告，NEEDED 库一致。




## 10-26 板测修正
- `npu_det.c`：新增 `R_OSD_CTRL 0x880`，NPU 使能时置 bit4/bit5（0x30）；复位值 0x60 不含检测框位，修复屏幕不画框。
- `npu_det.c`：`--out-zc` 改为默认（`g_opt.out_zc = 1`），新增 `--out-get` 回退到 `rknn_outputs_get`；零拷贝时统计里的 `get_avg` 仍打印 0。
- `npu_bench.c`：零拷贝输入改用局部副本，置 `type=UINT8 / fmt=NHWC / pass_through=0`，修复 INT8 误解导致的错误结果。
- `board_npu.sh`：新增 `MODEL` 环境变量（默认 `b3f_v8n_band_i8`），模型名与日志时间戳随模型变化；`--compare-out-zc` 的 Run A 改用 `--out-get`。