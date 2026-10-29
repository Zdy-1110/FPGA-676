# 工程构建说明 (BUILD)

本文件说明 FPGA 逻辑工程构建、RK3568 软件栈交叉编译及目标检测模型配置流程。

## 一、FPGA 逻辑工程构建

### 1.1 开发环境要求
- EDA 工具：紫光同创 Fabric Compiler (PDS) 2025.2 (build 211867) 或 2022.2-SP4
- 目标器件：Logos2 系列 PG2L100H-6FBG676
- 约束文件：`fpga/pnr/pango_pcie_top.fdc`

### 1.2 工程文件与生成命令
- 工程文件：`fpga/pnr/build_cam11.pds` (或子卡工程 `fpga/pnr/build_cam11_s1.pds`)
- 自动化构建脚本：`fpga/pnr/build_cam11.tcl`
- 构建流程（Tcl 交互模式）：
  ```tcl
  open_project fpga/pnr/build_cam11.pds
  compile -top_module pango_pcie_dma_top -force_to_run
  synthesize -ads -selected_syn_tool_opt 2 -force_to_run
  dev_map -force_to_run
  pnr -planning_before_place Enable -force_to_run -gplace_times 6 -seed_step 1 -pick_first_timing_convergence_seed TRUE
  report_timing
  gen_bit_stream -master_configuration_clock_frequency {25M} -force_to_run
  ```
- 产物输出：`generate_bitstream/pango_pcie_dma_top.sbit`（对应预编译 `quad_cam11.sbit`）

## 二、RK3568 软件栈交叉编译

交叉编译基于 Zig 0.14.1（`zig cc -target aarch64-linux-gnu.2.36`），编译脚本统一采用 `tools/rk_build.sh`。

### 2.1 主数据流与 ADAS 综合程序 (usb_feed)
命令如实源自 `tools/rk_build.sh:9-11`：
```sh
sh tools/rk_build.sh tools/usb_feed/usb_feed
```
实际构建展开命令：
```sh
zig cc -target aarch64-linux-gnu.2.36 -O2 -Wall \
    -I third_party/mpp-1.0.1/inc -I third_party/rknpu2-1.5.0/include \
    -I tools/adas -I tools/npu_det -I third_party/librga-1.9.1/include \
    -L third_party/rk_sysroot/usr/lib -Wl,--allow-shlib-undefined \
    tools/usb_feed/usb_feed.c tools/usb_feed/vdec_mpp.c tools/usb_feed/quad_npu.c \
    tools/usb_feed/quad_sched.c tools/usb_feed/adas.c tools/adas/tl_det.c tools/npu_det/npu_post.c \
    -I tools/npu_det -I tools/adas -I third_party/librga-1.9.1/include \
    -lrockchip_mpp third_party/rk_sysroot/usr/lib/librga.so.2.1.0 -lrknnrt -lpthread -lm -std=gnu99 \
    -o tools/usb_feed/usb_feed
```

### 2.2 车载菜单交互程序
```sh
sh tools/rk_build.sh tools/menu/usb_menu tools/menu/usb_menu.c -lpthread
sh tools/rk_build.sh tools/menu/mode_select tools/menu/mode_select.c
sh tools/rk_build.sh tools/menu/menu_daemon tools/menu/menu_daemon.c -lpthread
```

### 2.3 NPU 性能基准测试程序
源自 `tools/npu_det/PROGRESS.md:74`：
```sh
sh tools/rk_build.sh tools/npu_det/npu_bench tools/npu_det/npu_bench.c tools/npu_det/npu_post.c -lrknnrt -lm -std=gnu99 -Wextra
```

## 三、AI 检测模型说明

- 预转换模型：工程内包含适配 RK3568 NPU 的 INT8 量化模型：
  - `models/npu/b5_v6n_band.rknn`
  - `models/npu/b6_v6n_v3w.rknn`
  板端程序可直接加载使用。
- 离线模型转换脚本：
  脚本路径为 `tools/npu_convert/convert_rknn.py`，依赖 `rknn-toolkit2 1.5.0`，用于将 ONNX 模型量化转换为 RKNN 格式。
