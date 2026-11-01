# 附录 B  验证复现记录

> 目的：把技术报告中的关键指标变成**可复现**的结果。每条记录包含环境、命令、原始输出与对照结论。
> 复现时间：2026-10-30；代码基线：`199a725`（复现时的 HEAD）。

## B.1 环境

| 项 | 值 |
|---|---|
| 主机 | Windows 10/11，git-bash |
| 交叉编译 | Zig 0.14.1，`zig cc -target aarch64-linux-gnu.2.36` |
| Python（算法评测） | `.venv_yolo/Scripts/python.exe`，Python 3.13.7，OpenCV 5.0.0，NumPy 2.5.2 |
| 视频源 | `video_review/src/video_20260929_<id>.mp4`（官方 7 段） |

## B.2 交通灯 `tl_det` 全量复现

- 程序：`tools/adas/host_test/tl_host_main.exe`（与 Zig 重新编译版本结果一致）
- 命令：`bash tools/adas/host_test/run_host_test.sh`（全 7 段，含 `--ref` 与 `--no-ref` 两轮）
- 退出码：0；耗时：108 s（`--ref`）+ 104 s（`--no-ref`）

| 指标 | 报告值 | 复现值 | 结论 |
|---|---|---|---|
| 总帧数 | 2678 | 2678 | 一致 |
| RAW 逐帧一致 | 2678/2678（100.00%） | 2678/2678（100.00%） | 一致 |
| 独立 SIG 一致 | 2603/2678（97.20%） | 2603/2678（97.20%） | 一致 |
| SIG 用例通过 | 63/69（91.3%） | 63/69（91.3%） | 一致 |

逐视频（帧数 / RAW / 独立 SIG）：112454 36/36/36；112507 450/450/450；112739 926/926/858；113343 219/219/212；113421 131/131/131；113452 144/144/144；113539 772/772/772。

结论：报告中的交通灯指标可逐帧复现，无统计口径差异。

## B.3 车道线定点模型 32 用例复现

- 命令：`.venv_yolo/Scripts/python.exe tools/lane_fpga/eval.py`
- 退出码：0；耗时：75.4 s（4 段视频、4750 帧）

| 指标 | 报告值 | 复现值 | 结论 |
|---|---|---|---|
| 通过用例 | 16/32（50.0%） | 16/32（50.0%） | 一致 |
| 参考算法通过 | 17/32（53.1%） | 17/32（53.1%） | 一致 |

失败用例（16 个）：`112507-01/04/05/06/07/11/14/17/18/19`、`113343-03`、`113452-01`、`113539-06/07/08/09`。
失败分类：类型判定偏差 12 例（实线/虚线/双黄混淆），决策表决抖动 4 例，无候选点 0 例，拟合偏差 0 例。

参数核对（10 项，均与报告 §4.2 一致）：`y_top=260`、`y_bot=500`、`x_c=480`、`white_g_min=120`、`white_delta=18`、`yellow_r_min=130`、`yellow_g_min=120`、`yellow_b_diff=20`、`n_min=25`、`ema_alpha_shift=1`。

## B.4 斑马线定点模型评测复现

- 命令：`.venv_yolo/Scripts/python.exe tools/zebra_fpga/eval.py`
- 退出码：0；耗时：94.3 s

| 指标 | 报告值 | 复现值 | 结论 |
|---|---|---|---|
| 112454 事件时长覆盖 | 93.4%（3.30 s / 3.53 s） | 93.4%（3.30 s / 3.53 s） | 一致 |
| 112454 核心段逐帧命中 | 26/26 | 26/26 | 一致 |
| 113452（瓦楞板/SUV）误报 | 0 | 0 | 一致 |
| 112739 / 113343 误报 | 0 / 0 | 0 / 0 | 一致 |
| 113539 正样本段（64–69 s） | 0/51（遮挡） | 0/51（遮挡） | 一致 |

中间量：112454 每帧有效候选行 `n_rows` 仅 2–5（均值 3.75），门限 `r_min=3`，本身处于临界；这是板端对光照/遮挡敏感的根因之一。

## B.5 斑马线间隙门限扫描（模型级）

`gap_max_w ∈ {100,200,300,400,500,600}`，其余参数不变：

| gap | 112454（正） | 113539 核心段 | 113452（瓦楞板） | 112739 | 113343 | 112507 路口 |
|---|---|---|---|---|---|---|
| 100（默认） | 100% / 1 事件 | 0.0% | 0 事件 | 0 | 0 | 4 事件 |
| 200 | 100% / 1 | 37.3% / 1 | 0 事件 | 0 | 2 事件（1.5 s） | 4 事件 |
| 400 | 100% / 1 | 88.2% / 1 | **1 事件（1.0 s）** | 1 事件（0.5 s） | 2 事件 | 5 事件 |
| 600 | 100% / 1 | 100% / 1 | **1 事件（1.0 s）** | 1 事件（0.5 s） | 2 事件 | 5 事件 |

结论：放宽门限能救回遮挡段，但会击穿瓦楞板负样本并放大路口误报。**保持默认 100，不做 RTL 重综合**；完整表见 `tools/zebra_fpga/gap_sweep.md`。

## B.6 车道线门级后仿

- 工作区：`D:/pango_build/4_15_PCIE_DMA/sim/lane_gl`（`work_r6`），Questa `vsim`。
- **网表归属**：`impl.tcl`（2026-10-28）对 `rt_lane_det.v` 做**独立综合**，输入源 rt_lane_det.v 与提交位流 cam18 所用文件 MD5 一致（`0bced8fb6fffdd4f450c2d4a15a06b67`），网表取自 cam10f r6 独立综合。
- `seg_board`（2 帧）：`SEG seg_board: row_mismatch=0 frame_field_mismatch=0`，`Errors: 0`；日志 `log/lane_gl_repro_20261030/repro_board.log`。
- `seg_recover`（40 帧）：`SEG seg_recover: row_mismatch=0 frame_field_mismatch=0`，`Errors: 0`；日志 `log/lane_gl_repro_20261030/repro_recover40.log`（重跑耗时约 2 小时 15 分）。
- 结论：42 帧（2 + 40）逐帧一致，与第九章结论一致；全芯片 PnR 后的 SDF 反标未执行，时序收敛以 PDS STA 报告为准。

## B.7 复现命令汇总

```bash
# 交通灯（主机端 C）
bash tools/adas/host_test/run_host_test.sh

# 车道线模型（32 用例）
.venv_yolo/Scripts/python.exe tools/lane_fpga/eval.py

# 斑马线模型
.venv_yolo/Scripts/python.exe tools/zebra_fpga/eval.py

# 夜间增强 RTL 仿真（Questa FSE，期望 NIGHT_TB PASS）
cd fpga/sim_night
vlog +incdir+../src/disp ../src/disp/rt_night.v tb_rt_night.v
vsim -c -do run.do

# 夜间白天天光不误触发门槛统计（8024 帧，期望 GATE PASS）
.venv_yolo/Scripts/python.exe tools/night_eval/luma_stats.py

# 导航生成与单测（15 条 GT 指令生成 + 宿主单测 PASS）
python tools/nav_proto/make_navfile.py
zig cc -O2 -Itools/usb_feed tools/nav_proto/test_nav.c tools/usb_feed/nav.c -o test_nav && ./test_nav

# 一键构建与文档不变量自检
python tools/selftest.py
```

## B.8 复现过程中发现的实现缺陷

1. **斑马线配置总线错位**：`rt_ext_regs.v:145` 把 `reg_zebra_gap[7:0]` 拼到 `o_zebra_cfg_bus[47:40]`，而 `rt_disp_top.v:606` 从 `[39:32]` 取 `zebra_gap_pix`，该段恒为 0；`n_min`/`span` 也因总线宽度只含 `ctrl` 而取不到主机写入值。
   - 影响：`0xA20` 的高位与 `0xA2C` 实际无效，硬件始终使用 `rt_zebra_det.v` 的默认参数（`n_min=7`、`span_q10=550`、`gap_max_w=100`）。由于核内对 0 值有默认回退，功能不因此崩溃，但**参数不可调**。
   - 处置：列入第十一章改进项；是否重综合取决于门限扫描结论与许可证窗口。
2. **`0x82C` 只统计窗口 0**：`rt_disp_top.v:974` 在四宫格模式选通 `q0_sbus`，窗口 1–3 的欠载计数未引出（见第九章说明）。
