# 选题三 RK 端：USB 摄像头选型与容器帧合成方案（方案 B）

> 2026-10-17 制定。上级文档：`选题3_硬件层架构_双摄像头+HDMI降级方案.md` §1.2 方案 B。
> 标注说明：【确认】= 已对照原文核实；【待定】= 缺资料或需上板验证；【推断】= 设计推理，未实测。
> 制定时 RK 板离线。**2026-10-17 下午已上板核实**，结果见 §6.2：MPP、RGA、libdrm、GStreamer 的 Rockchip 插件都在，方案不需要改。
>
> **2026-10-18 架构变更：** 用户决定采用 **3 个 USB 摄像头 + FPGA 视频中枢**方案，见 `选题3_硬件架构_FPGA视频中枢方案_20261018.md`。对本文的影响：
> - USB 画面改为经 PCIe 送 FPGA。RK 端的主程序变为 usb_feeder（采集 → MPP 解码 → RGA 缩放 → 预留内存 → 写门铃）和 npu_infer；
> - 本文的 HDMI 容器帧合成（adas_vsrc）降为**评测测试视频（模式 T）和 PCIe 故障时的降级通路**，降级布局改为 2×2（W1–W3 为后、左、右）；
> - §2 摄像头选型要求、§6.2 / §6.2.1 板上核实结果（含 USB 拓扑）仍然有效。

---

## 1. 目标与原则

**目标：** RK3568 持续输出 1920×1080@30 的 HDMI 容器帧。W0（前）和 W1（后）的内容可以在"USB 摄像头"和"U 盘视频"之间切换；模式 T 时输出整帧 U 盘视频。

**原则：**

1. **HDMI 时序恒定。** 任何模式切换都只改像素内容，不重新设置显示模式，FPGA 的 MS7200 不会失锁。
2. **只保留最新帧。** 每个视频源只存最新一帧，合成时直接取最新的，不排队。合成环节最多增加 1 帧延迟。
3. **全程硬件处理。** MJPEG 用 JPEG 硬解（`JPEG_DEC`，`trm1.txt:566`），H.264/H.265 用 VPU（4K60 解码，`hw.txt:806-807`），缩放、颜色转换和拼接用 RGA（`trm1.txt:564`）。CPU 只负责调度。【确认：硬件模块存在；软件栈是否齐全待定】
4. **不依赖 PCIe。** PCIe 断开时，按配置文件里的默认模式运行。

**不在本文范围：** NPU 程序；PCIe 驱动（本文只定义它要给出的接口，见 §3.6）。

## 2. USB 摄像头选型要求

### 2.1 必须满足

| # | 项目 | 要求 | 原因 | 到货后怎么验 |
|---|---|---|---|---|
| 1 | 接口 | USB 2.0，UVC 免驱 | 内核 `uvcvideo` 直接识别，不用装驱动 | 插上后出现 `/dev/videoN`，dmesg 里有 uvcvideo |
| 2 | 输出格式 | MJPEG 1280×720@30（16:9）；最好同时支持 960×540@30 | 960×540 正好是一个窗口，可以省掉一次缩放；4:3 的 640×480 拉成 16:9 会变形 | `v4l2-ctl --list-formats-ext` |
| 3 | 帧率 | 两路同时开、室内灯光下，每路实测 ≥ 29.5 fps | 很多便宜摄像头在暗处会自动降到 15 fps | §6.3 的 S1 |
| 4 | 曝光 | 能关掉"曝光优先"（`exposure_auto_priority=0`）或支持手动曝光 | 保证帧率不随光线下降 | `v4l2-ctl -l` |
| 5 | 对焦 | 定焦 | 自动对焦会来回拉焦，影响识别 | — |
| 6 | 视场角 | 水平 90°–120°，低畸变 | 鱼眼（≥ 150°）会让车道线和目标变形，FPGA 车道检测和 NPU 识别都会变差 | 拍方格纸看畸变 |
| 7 | 功耗 | 每个 ≤ 1 W（5 V、200 mA） | 两个摄像头加 U 盘都从 RK 板的 USB 口取电 | USB 电流表 |
| 8 | 数量 | 2 个同型号 | 颜色和视场一致；前/后靠插的 USB 口区分 | — |
| 9 | 结构 | 板级模组（32×32 或 38×38 mm，M12 镜头）或带小外壳，线长 ≥ 1 m | 方便固定在车模或支架上 | — |

### 2.2 建议

- 选低照度好的传感器（星光级，如 IMX291 / IMX307 / IMX462 一类），对应赛题的"夜间道路"场景。
- 支持 WDR（宽动态），对应"强光"场景。
- **不要选：**
  - 只输出 H.264/H.265 的摄像头：编码有延迟，还有 GOP 问题，并且要占用 VPU；
  - USB 3.0 或 4K 摄像头：用不上，而且功耗大；
  - 需要外接电源的摄像头。

### 2.3 USB 带宽与接口分配

- MJPEG 720p30 每路约 2–6 MB/s【推断，取决于压缩质量】。YUYV 960×540@30 每路要 31 MB/s，超过 USB 2.0 单个等时端点的上限（3×1024 B / 125 µs ≈ 24.6 MB/s），所以**必须用 MJPEG**。
- OK3568-UP4 底板上有 USB3.0 双口（`sch.txt:1986`）、USB-A 双口（`sch.txt:1874`）和一颗 USB2.0 Hub FE1.1s（`sch.txt:1740`）【确认】。哪些口挂在 Hub 下面还不知道【待定，用 `lsusb -t` 查】。
- **分配原则：** 前、后摄像头各插一个**不在同一个 Hub 下**的口；U 盘插剩下的口。
- **设备命名：** 用 `/dev/v4l/by-path/…`（按物理端口命名），不要用 `/dev/videoN`（编号随插拔顺序变）。两个同型号摄像头的序列号经常相同，按端口区分是唯一可靠的办法。

## 3. RK 端软件架构

### 3.1 进程与线程

```
                 ┌──────────────────────── adas_vsrc（单进程，C） ─────────────────────────┐
 前摄像头 ─USB─► │ cam0 线程：V4L2 取 MJPEG ─► MPP JPEG 硬解 ─► NV12 dmabuf ─► 槽 S0（只留最新） │
 后摄像头 ─USB─► │ cam1 线程：同上                                          ─► 槽 S1          │
 U 盘文件 ─────► │ file 线程：GStreamer filesrc!decodebin(mppvideodec)!appsink ─► 槽 S2（按 PTS）│
                 │                                                                          │
                 │ compose 线程（由 DRM 翻页事件驱动，30 Hz）：                               │
                 │   取空闲输出缓冲 FB[k]（3 个 1920×1080 XRGB8888，轮换使用）               │
                 │   RGA：S0→W0、S1→W1（缩放 + NV12→RGB + 可选镜像）；没有信号的窗口填灰    │
                 │   写帧尾标签（§3.5）─► DRM 原子提交（非阻塞翻页）                        │
                 │                                                                          │
                 │ ctrl 线程：每 100 ms 读一次期望模式（PCIe 驱动 / 控制 FIFO / 配置文件）  │
                 └───────────────────────────────────────────────┬──────────────────────────┘
                                                                 ▼
                                             HDMI TX 1920×1080@30 ─► FPGA MS7200
```

用一个进程，是因为 DRM 输出只能有一个主控者（DRM master）。把所有视频源放在同一个进程里合成，比多个进程分别抢显示平面简单可靠。

### 3.2 模式与窗口来源

| 模式 | W0（0, 0, 960, 540） | W1（960, 0, 960, 540） | W2 / W3 | 说明 |
|---|---|---|---|---|
| Q-实拍（默认） | S0 前摄像头 | S1 后摄像头 | 深灰底 | 方案 B |
| Q-回放 | S2 U 盘视频 | 第二个视频文件；没配就用同一个 | 深灰底 | 方案 A |
| T | 整帧 1920×1080 = S2 | — | — | 评测用 |

**窗口降级：**

- 某个摄像头连续 300 ms 没有新帧，就把它的窗口标成"无信号"并填灰；也可以在配置里改成"改用 U 盘视频"。
- 后台每 2 s 尝试重新打开这个摄像头，恢复后自动切回。

### 3.3 各环节实现要点

| 环节 | 做法 | 要点 |
|---|---|---|
| V4L2 采集 | mmap 方式，3 个缓冲，用 `VIDIOC_EXPBUF` 导出 dmabuf | 缓冲少，排队就少；启动时设 `exposure_auto_priority=0` |
| MJPEG 解码 | MPP（`MPP_VIDEO_CodingMJPEG`），输入直接用 V4L2 导出的 dmabuf，输出 NV12 dmabuf | 每路一个 MPP 上下文；USB 传输出错的坏帧直接丢掉。MPP 用不了时退回 libjpeg-turbo 软解（两路 720p 约占 1 个核【推断】） |
| 文件解码 | 进程内跑一条 GStreamer 管线：`filesrc ! decodebin ! appsink`，caps 为 NV12，`sync=true max-buffers=1 drop=true`；从 GstBuffer 取 dmabuf fd | decodebin 会自动选 mppvideodec【待定】；播放到结尾时跳回开头循环 |
| 合成 | librga 的 im2d 接口（`improcess`，或 `imresize` + `imcvtcolor`）；源和目标都用 dmabuf 导入，目标是 FB[k] 中的窗口矩形 | 每帧只重画 W0/W1。W2/W3 和背景在 3 个缓冲初始化时各画一次 |
| 显示 | libdrm 原子接口：HDMI 连接器 + 对应 CRTC + 主平面。模式从 EDID 列表里选 1920×1080@30（VIC 34，像素钟 74.25 MHz）；列表里没有就按 CEA-861 时序自己构造 | 输出 RGB 8 bit；量化范围尽量设成全范围。Rockchip 驱动对应的连接器属性名【待定，用 `modetest -c` 查】 |
| 热插拔 | 监听 udev 的 drm change 事件；HDMI 重新连上后重新提交模式 | FPGA 每次 JTAG 加载都会复位 MS7200，触发一次 HPD |

### 3.4 延迟控制

- 每个槽只存最新一帧（mailbox 方式），合成总是取最新的，不排队。
- 上一次翻页完成后立刻开始合成。RGA 处理两个窗口约 3–6 ms【推断】，所以合成加上等待显示，最多增加约 1 帧（33 ms）。
- 主文档 §7.1 估算方案 B 端到端 110–170 ms。其中 RK 内部的部分：UVC 采集 33–66 ms（在摄像头内部，控制不了）+ 解码和合成 ≤ 10 ms + 等待翻页 ≤ 33 ms。
- 实测不够时再做的优化：
  - 把合成推迟到 vblank 前约 8 ms 再开始；
  - 改用 VOP2 叠加平面直接扫描 NV12，省掉 RGA 拷贝。但哪些平面能用在 HDMI 上取决于设备树【待定】。

### 3.5 帧尾标签（带内信令，建议做）

**要解决的问题：** PCIe 不稳定时，FPGA 不知道容器帧当前是哪种布局、哪个窗口有有效画面。办法是 RK 在每帧底部写一个机器可读的标签，FPGA 从 HDMI 数据里直接读出来。

- **位置：** y = 1072–1079（最后 8 行），x = 0–255，共 32 个 8×8 的像素块。每块纯黑表示 0，纯白表示 1。
  - 模式 Q 时这里是 W2 窗口的左下角（空闲区）；模式 T 时会盖住测试视频最底部 8 行（占 0.7%），不影响识别。FPGA 显示时可以把这 8 行涂黑。
- **为什么用纯黑/纯白块：** 即使 HDMI 做了 RGB 限幅（16–235）或经过 YUV 转换，用阈值 128 仍能可靠判读。
- **32 位内容：**

| 位 | 内容 |
|---|---|
| 31–24 | 魔数 0xA5 |
| 23–22 | 布局：0 = Q，1 = T |
| 21–20 | W0 来源：0 = 无信号，1 = 摄像头，2 = 文件 |
| 19–18 | W1 来源（编码同上） |
| 17–16 | 保留 |
| 15–4 | 帧计数（12 位，每输出一帧加 1） |
| 3–0 | 校验：前 28 位每 4 位一组相互异或 |

- **量化范围校准块：** x = 256–271 放一个纯白块，x = 272–287 放一个纯黑块。FPGA 读出实际像素值：255/0 是全范围，235/16 是限幅。
- **FPGA 侧：** HDMI 采集模块在 y = 1076 这一行，每 8 个像素在块中心采样一次（x = 8i + 4），预计约 100 个 LUT【推断】。用途：
  - 布局和 FPGA 当前显示模式不一致时，OSD 给出提示；
  - 帧计数不再变化，说明 RK 卡死；
  - 统计 RK 的实际输出帧率；
  - PCIe 正常时，FPGA 把解码出的帧计数放进 BAR0 状态寄存器，RK 回读，可以算出 RK 到 FPGA 的传输延迟。

### 3.6 控制接口

期望模式的来源，按优先级从高到低：

1. **FPGA 按键：** KEY4 短按切 Q/T，长按（≥ 1 s）切实拍/回放 → 写入 BAR0 0x008 → PCIe 驱动 → adas_vsrc。
2. **控制 FIFO：** `/run/adas_vsrc.ctl`，例如 `echo "mode=Q src=live" > /run/adas_vsrc.ctl`，SSH 调试时用。
3. **配置文件：** `/etc/adas_vsrc.conf` 中的默认值，开机时和 PCIe 断开时使用。

**adas_vsrc 不直接 mmap BAR0。** 链路断开时访问 BAR，在 RK3568 上可能触发总线异常，导致死机【推断：10-15 链路掉线时 RK 的 PCIe 控制器曾自行重新初始化，也出现过 RK 卡死】。应由 PCIe 驱动先检查链路状态，再通过 sysfs 或字符设备把模式位交给 adas_vsrc。驱动做好之前，只用第 2、3 种方式。

### 3.7 配置文件示例

```ini
# /etc/adas_vsrc.conf
cam_front   = /dev/v4l/by-path/<前摄像头端口>-video-index0
cam_rear    = /dev/v4l/by-path/<后摄像头端口>-video-index0
cam_fmt     = mjpeg 1280x720@30
rear_mirror = 0                      # 1 = 后视画面水平镜像
file_front  = /media/usb0/           # 填目录时，播放目录里的第一个视频文件
file_rear   =                        # 留空 = 与 file_front 相同
default_mode = Q                     # Q 或 T
default_src  = live                  # live（实拍）或 file（回放）
on_cam_lost  = gray                  # gray（填灰）或 file（改用 U 盘视频）
```

### 3.8 开机流程

1. 新增启动脚本 `/etc/init.d/S95adas_vsrc`。
2. **需要停用 `S49weston` 和 `S99matrix-browser`（飞凌的演示浏览器）。** Weston 占着 DRM 主控权，adas_vsrc 拿不到显示输出。这是对板子启动配置的持久修改，**动手前要先征得你同意**，并备份原脚本。
3. adas_vsrc 启动后的顺序：
   1. 等待 HDMI 连接（FPGA 已上电并完成配置）；
   2. 设置 1080p30，先输出测试图（彩条 + 标签）；
   3. 摄像头和文件就绪后切到正常画面；
   4. U 盘晚插也能自动发现（监听 `/media` 下的挂载）。

## 4. 资源估算【推断】

| 资源 | 占用 |
|---|---|
| CPU（4 × A55） | 主要是线程调度和 V4L2/MPP 调用，预计不到单核的 15% |
| JPEG 硬解 | 2 路 720p30 |
| VPU | 模式 T 或回放时，1 路 1080p 视频 |
| RGA | 每帧写 2 个 960×540 窗口（模式 T 时写 1 个 1920×1080），约 4–8 MB/帧 |
| 内存 | 3 个输出缓冲共 25 MB，加上解码缓冲，总计不到 100 MB |

NPU 不受影响：NPU 的输入仍是 FPGA 经 PCIe 送回的 4 路抽取帧（主文档 §9）。

## 5. 构建环境

**现状【确认】：**

- PC 上没有 aarch64 Linux 交叉编译器。
- WSL2 起不来，报 `HCS_E_HYPERV_NOT_INSTALLED`，需要在 BIOS 里开启虚拟化。
- 之前的 pcie_bench 是用 st-arm-clang 编的 ARM32 独立程序，这条路链接不了 libdrm、MPP、RGA。

**可选方案：**

| 方案 | 做法 | 需要你做什么 |
|---|---|---|
| Z | Zig 自带 clang，可以在 Windows 上直接编 aarch64-linux-gnu 程序，并指定与板子一致的 glibc 版本 | 同意下载 Zig（Windows 版 zip，约 50 MB） |
| W | 在 BIOS 开启虚拟化 → WSL2 Ubuntu → `apt install gcc-aarch64-linux-gnu` | 进 BIOS 改设置 |
| F | 用飞凌 OK3568 Linux SDK 自带的工具链 | SDK 很大，并且要 Linux 主机 |

10-17 核实板上 glibc 是 2.36（§6.2），比 Ubuntu 22.04 的 2.35 新，所以 Z 和 W 都可行，难度相当。W 还多一个完整的 Linux 环境，以后也用得上。

**sysroot 的准备：**

- 库文件：从板子上拷 `/lib`、`/usr/lib` 中用到的 .so，包括 libdrm、librockchip_mpp、librga、libgstreamer-1.0、libgstapp-1.0、libglib-2.0 等。
- 头文件：取与板上版本对应的源码，包括 rockchip mpp、librga、libdrm，以及 gstreamer/glib 的 -dev 包。版本号在 §6.1 查。
- **下载任何东西之前都会先问你。**

## 6. 上板核实与验收

### 6.1 只读环境清单（板子上电后用 `tools/rk_ssh.py` 执行）

```sh
cat /etc/os-release; uname -a; ldd --version | head -1
ls /usr/lib /lib | grep -E "rga|mpp|drm|gst|jpeg|avformat"
gst-inspect-1.0 2>/dev/null | grep -i -E "mpp|rga|kms|v4l2|appsink|compositor"
ls -l /dev/video* /dev/v4l/by-path/ /dev/dri/ /dev/rga /dev/mpp_service 2>&1
lsusb -t
modetest -c 2>/dev/null | grep -A60 HDMI | head -80
zcat /proc/config.gz 2>/dev/null | grep -E "USB_VIDEO_CLASS|DRM_ROCKCHIP|ROCKCHIP_RGA"
ps | grep -E "weston|browser|rkaiq"
which v4l2-ctl media-ctl python3
```

以上命令都只读取信息，不改变板子状态。

### 6.2 2026-10-17 核实结果【确认】

原始输出：`log/rk_env/inventory_20261017.log`、`hdmi_state_20261017.log`、`hdmi_after_4_12.log`。

| 项目 | 结果 | 对方案的影响 |
|---|---|---|
| 系统 | Buildroot 2021.11，内核 5.10.160，**glibc 2.36**；没有 ldd、python3 和编译器 | 用 Ubuntu 22.04（glibc 2.35）的交叉编译器编出的程序可以直接运行，WSL2 方案不需要额外处理 sysroot |
| 硬件编解码 | `librockchip_mpp`、`/dev/mpp_service`；内核开了 `ROCKCHIP_MPP_JPGDEC`、RKVDEC/RKVDEC2 | MJPEG 和 H.264/H.265 硬解可用 |
| RGA | `librga.so.2.1.0`、`/dev/rga` | im2d 接口可用；头文件取 librga 2.1.0 版本 |
| 显示 | `libdrm.so.2.4.x`、`modetest`；card0 = 显示，card1 是另一个 DRM 设备（推断为 NPU） | — |
| GStreamer | 1.22.0，有 `mppjpegdec`、`mppvideodec`、`kmssink`、`appsink`、`v4l2src`、`qtdemux`、`matroskademux`、`h264parse`/`h265parse`、`videotestsrc`、`fpsdisplaysink`；**没有 `compositor`** | 确认合成要自己用 RGA 做；文件解码按计划走 appsink |
| 其他 | `v4l2-ctl`、`media-ctl`、`ffmpeg`（libavformat 58，即 FFmpeg 4.4）、libturbojpeg | libturbojpeg 可以作 MJPEG 软解的后备 |
| UVC | `CONFIG_USB_VIDEO_CLASS=y`（编进内核） | USB 摄像头插上即用 |
| USB | 总线 1 上有一个 1a40:0101 Hub（即 FE1.1s） | 哪个物理口在 Hub 下，等摄像头插上后看设备路径 |
| 显示占用 | Weston 和 matrix-browser 在运行；Weston 占用 VP1（DSI 1024×600）和 VP2（LVDS 1280×800）；**HDMI 在 VP0，当前空闲** | adas_vsrc 仍要先停 Weston（DRM 主控权按设备分，不按输出口分） |
| 已有的 /dev/video0–16 | 都是 rkcif / rkisp 的 MIPI 通道，与 UVC 无关 | UVC 摄像头插上后编号从 17 往后排，所以必须用 by-path 命名 |
| 内存 / 存储 | 3.9 GB 内存（3.4 GB 空闲），根分区剩 4.9 GB | 足够 |
| HDMI 状态 | 载入 4_12 环出例程前后，HDMI-A-1 都是 disconnected，dw-hdmi 的 PHY_STAT0 = 0x00（没有 HPD） | 待查：RK→FPGA 的 HDMI 线是否接好，或 MS7200 是否输出 HPD |

### 6.2.1 RK USB 拓扑（2026-10-18 只读核实）与 3 路 USB 摄像头变体

`/sys/bus/usb/devices`、`/sys/kernel/debug/usb/devices`：

| 总线 | 控制器 | 下面接的 | 带宽 |
|---|---|---|---|
| 5（USB2）/ 6（USB3） | xhci-hcd.0.auto（推断为 DT 节点 usbdrd，即 OTG0） | 1 个口 | 独立的一条 480M + 5G |
| 7（USB2）/ 8（USB3） | xhci-hcd.1.auto（推断为 usbhost，即 HOST1） | 1 个口 | 独立的一条 480M + 5G |
| 1 | EHCI fd800000（HOST2） | 板载 4 口 USB2 Hub 1a40:0101 | 4 个口**共用**一条 480M |
| 2 | EHCI fd880000（HOST3） | 1 个口，当前没接设备 | 独立 480M（物理位置未知） |

结论：要接 3 个摄像头，应当一个 USB3 口接一个、Hub 口接一个，让 3 个摄像头各占一条总线。不要把 2 个摄像头接在同一个 Hub 上：很多 UVC 摄像头开 MJPEG 时会按最大值预留等时带宽，同一条 USB2 总线上通常只容得下 1–2 个。物理口与总线的对应，等插上设备后看 by-path 确认。

3 路时的容器布局改为 2×2：W0、W1、W2 各 960×540，第 4 格放帧尾标签和状态信息。FPGA 从 HDMI 裁出 3 路，加上 FMC 双目 2 路，共 5 个逻辑通道。

### 6.3 分阶段验收

| 阶段 | 内容 | 通过标准 |
|---|---|---|
| S0 | 执行 §6.1 清单 | 确认 MPP、RGA、libdrm、GStreamer（含 mppvideodec/mppjpegdec）都在，并定下构建方案 |
| S1 | 摄像头单测：两路同时 `v4l2-ctl --stream-mmap --stream-count=300`；再用 `gst-launch-1.0 … ! mppjpegdec ! fakesink` 验证硬解 | 每路 ≥ 29.5 fps，dmesg 无 USB 错误 |
| S2 | 打通 HDMI 通路：程序还没写好时，先用 `gst-launch-1.0 videotestsrc ! … ! kmssink` 给 FPGA 的 4_12 例程（HDMI 环出）供图；之后换成 adas_vsrc 的测试图（彩条 + 标签） | 显示器画面稳定；FPGA 读到白块是 255 还是 235，据此定量化范围 |
| S3 | 两路摄像头进 W0/W1 | 连续 30 分钟不丢帧（标签帧计数连续）；拔掉一个摄像头，窗口变灰，插回后 2 s 内恢复 |
| S4 | 加入 U 盘文件：模式 T 和 Q-回放，循环播放 | H.264 和 H.265 的 1080p 文件各一个都能播；切换模式时 HDMI 不失锁 |
| S5 | 开机自启；FPGA 重新加载后自动恢复；实测延迟 | 冷启动到出画面 < 30 s【目标值】；前/后两路端到端延迟实测值写回主文档 §7.1 |

- S1、S2 需要临时停掉 Weston（`/etc/init.d/S49weston stop`，重启后自动恢复）。这一步同样要你同意后再做。
- S2 中 kmssink 可能选到 1080p60 而不是 1080p30。S2 只验证通路，60 Hz 也没关系，4_12 例程本身就是 1080p60 输入。

## 7. 分工

- **方案与审阅：** 本方案、adas_vsrc 接口规范、代码审查、上板操作（只读核实；停启 Weston 这类改动先确认）。
- **实现：** 按规范编写 adas_vsrc（预计 1000–1500 行 C）和构建脚本，按 S2 → S5 分四次交付，每次审完 diff 再上板。

## 8. 待确认事项

| # | 事项 | 怎么解决 |
|---|---|---|
| 1 | 板上有没有 MPP、librga、GStreamer 的 Rockchip 插件，各是什么版本 | §6.1 |
| 2 | 哪些 USB 口挂在 Hub 下 | `lsusb -t` |
| 3 | HDMI 输出格式和量化范围的属性名 | `modetest -c`；S2 实测白块 |
| 4 | MS7200 的 EDID 里有没有 1080p30 | `modetest -c` 看模式列表；没有就由 adas_vsrc 自建模式，或改 FPGA 侧的 EDID |
| 5 | 停用 Weston 后，飞凌的其他服务是否受影响 | 停用前列出依赖。rkaiq_3A 是 MIPI 摄像头的 ISP 服务，与 UVC 无关【推断】 |
| 6 | 构建环境用哪种 | 由你在 §5 的 Z / W / F 中选 |
| 7 | 摄像头实际延迟 | S5 实测 |
