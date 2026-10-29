# 附录 C  术语与缩写

| 缩写/术语 | 全称 | 在本项目中的含义 |
|---|---|---|
| ADAS | Advanced Driver Assistance System | 高级驾驶辅助系统；本项目实现红绿灯判决、变道合规、危险目标预警 |
| APM | Adder/Multiplier block | 盘古 FPGA 内的乘加硬核；本设计占用 61/240 |
| BEV | Bird's Eye View | 俯视/鸟瞰视图；本项目保留标定与透视图层，未做完整环视融合 |
| CMA | Contiguous Memory Allocator | Linux 连续物理内存；本项目预留 256 MB 给视频/NPU 缓冲 |
| DMA | Direct Memory Access | 直接内存访问；本项目指 PCIe 门铃触发的 FPGA Master 读 |
| DMA-BUF | DMA Buffer | 内核跨设备共享缓冲，MPP/RGA/PCIe 零拷贝的基础 |
| DRM | Dedicated RAM Module | 盘古 FPGA 的块存储（等效 BRAM）；本设计占用 99/155 |
| FF | Flip-Flop | 触发器；本设计占用 25,730/133,200 |
| FUSE | Filesystem in Userspace | 用户态文件系统；exFAT U 盘在板端走 FUSE |
| GBK | 汉字内码扩展规范 | 中文位图字库的索引编码 |
| HOLD3 | Hold ≥ 3 s | 按键事件类型 3；KEY4 按住 3 s 进入 cal_mode |
| LUT | Look-Up Table | FPGA 查找表；本设计占用 26,645/66,600 |
| MPP | Media Process Platform | 瑞芯微硬件编解码库；用于 H.264/H.265 硬解 |
| NPU | Neural Processing Unit | RK3568 神经网络加速器；运行 YOLOv6n INT8 |
| OSD | On-Screen Display | 屏幕叠加层；本项目含文本、框、箭头、告警边框 |
| PCIe | Peripheral Component Interconnect Express | 本系统用 Gen2 ×2 连接 RK3568 与 FPGA |
| PDS | Pango Design Suite | 紫光同创 FPGA 综合/布局布线工具链 |
| RGA | Raster Graphic Acceleration | 瑞芯微 2D 加速器；做缩放与 YUV/RGB 转换 |
| RKNN | Rockchip Neural Network | 瑞芯微 NPU 模型格式；本项目 `b5_v6n_band.rknn` |
| ROI | Region of Interest | 感兴趣区域；车道线/斑马线的检测带 |
| SWRR | Smooth Weighted Round-Robin | 平滑加权轮询；四路 NPU 调度权重 2:1:1:1 |
| WNS/TNS | Worst Negative Slack / Total Negative Slack | 时序最差余量/总负余量；cam11 为 +0.340 ns / 0 |
| 门铃 DMA | Doorbell DMA | SoC 写 0x190–0x19C 参数后 FPGA 自主搬帧的机制 |
| 四宫格 | Quad View | 1920×1080 均分 4 个 960×540 视口，slot0–3 |
| 基线 | Baseline | 按键相对状态基准；抵消菜单 KEY0/KEY1 对驾驶状态的污染 |
