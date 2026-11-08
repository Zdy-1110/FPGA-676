# 工程构建说明 (BUILD)

本文件说明 FPGA 逻辑工程构建、RK3568 软件栈交叉编译及目标检测模型配置流程。

## 零、单命令流程

```sh
pds_shell -f fpga/pnr/build_portable.tcl   # FPGA 位流（相对路径，换机器无需修改）
sh tools/build_all.sh                      # 板端全部程序
python tools/selftest.py                   # 构建 + 脚本 + 资产自检
```

完整移植步骤见 `docs/submit/PORTING.md`。

## 一、FPGA 逻辑工程构建

### 1.1 开发环境要求
- EDA 工具：紫光同创 Fabric Compiler (PDS) 2025.2 (build 211867) 或 2022.2-SP4
- 目标器件：Logos2 系列 PG2L100H-6FBG676
- 约束文件：`fpga/pnr/pango_pcie_top.fdc`

### 1.2 工程文件与生成命令
- 自动化构建脚本：`fpga/pnr/build_portable.tcl`（推荐，纯相对路径）；`fpga/pnr/build_cam23.tcl` 使用原开发机的绝对工程路径，换机请用 build_portable.tcl。脚本含 `rt_zoom_ana.v`（ZOOM2X 全屏模式下为分析核抽取 960×540 分析流），运行 6 seed 布局布线
- 构建流程（Tcl 交互模式或 `pds_shell` 执行）：
  ```tcl
  # 直接运行构建脚本：
  source fpga/pnr/build_cam23.tcl
  ```
  其核心流程等价展开为：
  ```tcl
  open_project <原开发机工程目录>/4_15_PCIE_DMA/pnr/pg2l_pcie_dma.pds
  # 加载 rt_disp_win_reader.v, rt_lane_det.v, rt_zebra_det.v, rt_night.v, rt_zoom_ana.v 等源码
  compile -top_module pango_pcie_dma_top -force_to_run
  synthesize -ads -selected_syn_tool_opt 2 -force_to_run
  dev_map -force_to_run
  pnr -planning_before_place Enable -force_to_run -gplace_times 6 -seed_step 1 -pick_first_timing_convergence_seed FALSE
  report_timing
  gen_bit_stream -master_configuration_clock_frequency {25M} -force_to_run
  ```
- 产物输出：`prj_tasks/pnr_1/generate_bitstream/pango_pcie_dma_top.sbit`（构建脚本自动复制为预编译位流 `quad_cam23.sbit`）

## 二、RK3568 软件栈交叉编译

交叉编译基于 Zig 0.14.1（`zig cc -target aarch64-linux-gnu.2.36`），编译脚本统一采用 `tools/rk_build.sh`。

### 2.1 主数据流与 ADAS 综合程序 (usb_feed)
命令源自 `tools/rk_build.sh:9-11`：
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
NPU 性能基准测试程序的交叉编译命令（编译 0 错误、0 警告）：
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

## 四、单命令自检

```sh
python tools/selftest.py          # 全量：menu_daemon / mode_select / usb_menu / usb_feed + 脚本语法 + 文档不变量
python tools/selftest.py --quick  # 跳过最慢的 usb_feed
```

自检覆盖：交叉编译（`-Wall -Wextra`，0 warning）、`run_boot.sh` 与 `S99adas_menu` 的 `sh -n`、文档章节数与禁用表述、图片与字库资产完整性。退出码 0 表示全部通过。

## 五、现场诊断

```sh
python tools/rk_diag.py 192.168.3.51
```

检查 PCIe 端点使能/速率/宽度、固件版本 `0x838`、显示主控 `0x800`、欠载 `0x82C`、门铃计数、关键进程、U 盘挂载与 CMA 余量；任一项失败返回 1。
