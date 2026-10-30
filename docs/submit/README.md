# 基于 FPGA+RK3568 软硬协同的高性能车载 ADAS 系统

基于紫光同创 PG2L100H FPGA 与瑞芯微 RK3568 SoC 软硬协同架构的高性能车载高级驾驶辅助系统 (ADAS)（2026 嵌赛紫光同创杯选题三参赛工程源码）。

## 一、系统架构

1. 视频输入：USB UVC 摄像头实时采集前向行车画面，经 RK3568 MPP 与 RGA 进行高效硬件解码与预处理。
2. 智能感知：RK3568 NPU 运行轻量定点化神经网络完成目标与红绿灯识别，纯 C ADAS 决策引擎判决行驶行为。
3. 异构互联：RK3568 与 FPGA 经 PCIe 2.0 x2 高速低时延互联，控制采用 MMIO，图像通过物理连续内存零拷贝 DMA。
4. 硬件流水：FPGA 硬件实现流式车道线与斑马线检测流水线，多路视频流汇聚写入板载 32 位 DDR3 帧缓存。
5. 视觉中枢：FPGA 硬件四宫格图层合成器在光栅扫描时实时叠加矢量指示与多图层 OSD，经 MS7210 输出 1080P@60Hz HDMI。

## 二、目录树

```text
.
├── fpga/        # 紫光同创 FPGA 工程 (PDS)、RTL 源码、IP 核与物理管脚约束
├── tools/       # RK3568 ADAS 软件栈 (usb_feed/menu/adas/npu_det) 与构建工具链
├── models/      # 预量化的 RKNN INT8 目标检测模型与结构配置
├── prebuilt/    # 预编译 FPGA 比特流 (.sbit) 与车载菜单素材 (ui_cjk.bin, tile/sel)
└── docs/        # 系统技术文档、大纲与构建部署说明
```

## 三、Quick Start

1. 交叉编译 RK 端程序：
   `sh tools/rk_build.sh tools/usb_feed/usb_feed`
2. 加载 FPGA 比特流：
   在上位机通过 Fabric Configuration 将 `prebuilt/fpga/quad_cam17.sbit` 下载至 FPGA
3. 板端启动 ADAS 主控：
   `/userdata/quad/usb_feed --bar1 0xf0204000 --dst 960x540 --slot0-rgb565`

## 四、硬件需求

1. FPGA 核心板：紫光同创盘古 100Pro+ (PG2L100H-6FBG676)
2. 边缘计算 SoC：飞凌嵌入式 OK3568-C 单板计算机 (插于 P29 槽位，PCIe Gen2 x2)
3. 图像输入：标准 UVC USB 摄像头 (支持 1080P/720P 输出)
4. 显示输出：标准 1080P@60Hz HDMI 显示器及线缆
5. 供电配套：12V/3A 稳压直流供电电源及调试串口

## 五、团队与日期

- 参赛团队：[参赛队名占位]
- 团队成员：[成员姓名占位]
- 指导教师：[教师姓名占位]
- 参赛高校：[高校名称占位]
- 日期：2026-10-30
