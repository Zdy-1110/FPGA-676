# 基于 FPGA + RK3568 的车载 ADAS 系统

2026 年全国大学生嵌入式芯片与系统设计竞赛（紫光同创杯）选题三参赛工程。
紫光同创 PG2L100H FPGA 承担视频接入、车道线/斑马线硬件检测与多图层视频合成，
RK3568 承担 NPU 目标检测与 ADAS 决策，两者通过 PCIe 2.0 x2 互联。

源码仓库：<https://github.com/Zdy-1110/FPGA-676>

## 系统组成

1. 视频输入：USB UVC 摄像头采集，RK3568 侧经 MPP/RGA 硬件解码与预处理。
2. 智能感知：RK3568 NPU 运行 INT8 量化模型，C 语言决策引擎输出行驶行为。
3. 异构互联：PCIe Gen2 x2，控制走 MMIO，图像走物理连续内存零拷贝 DMA（实测板卡到主机 896 MB/s）。
4. FPGA 流水：流式车道线与斑马线检测、自适应夜间增强、ZOOM 2X 分析，多路视频汇聚写入板载 32 位 DDR3 帧缓存。
5. 显示输出：四宫格图层合成与矢量 OSD 叠加，1080P@60Hz HDMI 输出（MS7210）。

## 目录

| 路径 | 内容 |
| --- | --- |
| `fpga/` | PDS 工程与管脚约束、RTL 源码（`src/`）、IP 核、仿真工程（`sim*/`）、历史位流（`out/`） |
| `tools/usb_feed/` | 板端主程序：采集、MPP 解码、四分屏调度、NPU 推理、ADAS 决策 |
| `tools/menu/` | 车载菜单、开机模式选择与守护脚本 |
| `tools/adas/`、`tools/npu_det/` | 决策引擎、NPU 后处理与板端基准 |
| `tools/lane_fpga/`、`tools/zebra_fpga/` | 车道线与斑马线检测的 PC 端黄金模型与评测 |
| `models/npu/` | 预量化 RKNN 模型 |
| `prebuilt/` | cam23 预编译位流（`fpga/quad_cam23.sbit`）与菜单字库/图素 |
| `evidence/` | cam23 时序（rtr）、资源（dmr）与多 seed 结果 |
| `docs/` | 技术文档、附录与现场运行手册 |
| `docs/submit/` | 构建、部署与第三方组件说明（随源码包提交） |

## 构建与运行

- FPGA 位流：直接用 `prebuilt/fpga/quad_cam23.sbit`，或运行 `pds_shell -f fpga/pnr/build_portable.tcl` 重建（PDS 2025.2，PG2L100H-6FBG676）
- RK3568 交叉编译：`sh tools/build_all.sh`（或单模块 `sh tools/rk_build.sh tools/usb_feed/usb_feed`）
- 移植与部署：`docs/submit/PORTING.md`
- 板端部署与开机脚本：`docs/submit/DEPLOY.md`
- 全量自检：`python tools/selftest.py`

## 文档

- 技术文档：`docs/技术文档_最终稿.md`（寄存器映射见附录 A，验证复现见附录 B）
- 运行手册：`docs/演示现场运行手册.md`

## 第三方组件

MPP、RKNN、librga 等组件来源与许可证见 `docs/submit/THIRD_PARTY.md`。
