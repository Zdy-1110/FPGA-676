# 移植与部署说明 (PORTING)

本文件面向拿到源码包的评委：在**相同器件**（紫光同创 PG2L100H + 飞凌 OK3568-C）上，按本文四步即可复现整套系统。所有路径均相对包根目录，包可整体拷贝到任意位置。

## 一、环境要求

| 项目 | 版本 / 型号 | 用途 |
| --- | --- | --- |
| FPGA 器件 | Logos2 PG2L100H-6FBG676 | 盘古 100Pro+ 核心板 |
| FPGA 工具链 | PDS 2025.2（build 211867） | 综合、布局布线、位流生成、Fabric Configuration 下载 |
| 主机 SoC | RK3568（飞凌 OK3568-C，插 P29 槽） | NPU 推理、ADAS 决策、显示菜单 |
| 交叉编译器 | Zig 0.14.1（`zig cc -target aarch64-linux-gnu.2.36`） | 板端程序编译 |
| 脚本环境 | Python 3.10+、Git Bash（Windows）或任意 POSIX sh | 打包、自检、诊断脚本 |
| 仿真（可选） | Questa / ModelSim | `fpga/sim*/` 下的回归 |

第三方运行库（MPP 1.0.1、RKNN 1.5.0、librga 1.9.1 的头文件与 aarch64 链接库）已随包放在 `third_party/`，无需额外下载。

## 二、包内结构

```text
fpga/             PDS 工程（pnr/pg2l_pcie_dma.pds，全部相对路径）+ RTL + IP + 仿真
  pnr/build_portable.tcl   便携构建脚本（仓库相对路径，无绝对路径）
  src/                     RTL 源码（disp 显示/检测流水线、cam 摄像头、ddr 等）
  ip/                      PCIe、DDR3、RAM IP
tools/
  rk_build.sh      交叉编译封装（自动定位仓库根目录与 zig）
  build_all.sh     一键编译全部板端程序
  usb_feed/        主程序：采集、解码、四分屏调度、NPU、ADAS 决策
  menu/            开机选择、U 盘浏览器、守护脚本
  npu_det/         NPU 后处理与板端基准
  adas/            决策引擎（tl_det 等）
  lane_fpga/ zebra_fpga/ night_eval/ nav_proto/   算法黄金模型与评测
  npu_train/ npu_convert/                        训练与 RKNN 转换脚本
third_party/      MPP / RKNN / librga 头文件与 aarch64 链接库
models/npu/       预量化 RKNN 模型（b5_v6n_band.rknn 为主用模型）
prebuilt/         cam23 位流（sbit/sfc）与菜单字库、图素
evidence/         板端工具导出的 cam23 时序/资源报告
log/              文档引用的训练、压测与后仿日志（路径与正文一致）
docs/submit/      本说明、构建说明（BUILD.md）、部署说明（DEPLOY.md）
```

## 三、四步复现

### 步骤 1：烧写（或重建）FPGA 位流

直接用包内预编译位流，无需综合：

1. PDS 打开 **Fabric Configuration**，连接下载器；
2. 选择 `prebuilt/fpga/quad_cam23.sbit` 下载到 FPGA（掉电丢失）；
3. 需要掉电保持时，用 `prebuilt/fpga/quad_cam23.sfc` 烧写板载 SPI Flash（W25Q128 / XT25BF128 系列），烧写前先在 RK 上断开 PCIe 链路，步骤见 `docs/submit/DEPLOY.md §三`。

修改 RTL 后重新构建：

```sh
pds_shell -f fpga/pnr/build_portable.tcl
# 产物：out/quad_cam23.sbit、out/cam23_reports/{rtr,dmr,multiseed}.csv
```

也可在 PDS GUI 中打开 `fpga/pnr/pg2l_pcie_dma.pds`，在 Tcl 控制台 `source fpga/pnr/build_portable.tcl`。脚本内全部路径相对仓库根目录，整包换机器后无需改路径。

构建完成后回读版本寄存器确认：`devmem 0xf0204838 32` 应为 `0x20261106`（cam23）。

### 步骤 2：交叉编译板端程序

```sh
sh tools/build_all.sh
```

该脚本依次编译 `mode_select`、`menu_daemon`、`usb_menu`、`usb_feed`、`npu_bench`、`fcam_rb`，产物写在各自源码目录。若 zig 不在 PATH，用环境变量指定：

```sh
ZIG=/path/to/zig sh tools/build_all.sh
```

只想编译主程序时：

```sh
sh tools/rk_build.sh tools/usb_feed/usb_feed
```

### 步骤 3：部署到板端

把下列文件拷到板端 `/userdata/quad/` 并 `chmod +x`：

| 来源 | 板端位置 |
| --- | --- |
| `tools/usb_feed/usb_feed` | `/userdata/quad/usb_feed` |
| `tools/menu/usb_menu` | `/userdata/quad/usb_menu` |
| `tools/menu/mode_select` | `/userdata/quad/mode_select` |
| `tools/menu/menu_daemon` | `/userdata/quad/menu_daemon` |
| `tools/menu/run_boot.sh` | `/userdata/quad/run_boot.sh` |
| `models/npu/b5_v6n_band.rknn` | `/userdata/quad/b5_v6n_band.rknn` |
| `prebuilt/menu/ui_cjk.bin` | `/userdata/quad/ui_cjk.bin` |
| `prebuilt/menu/tile*.*`、`sel*.*` | `/userdata/quad/menu/` |

再装开机脚本：

```sh
cp tools/menu/S99adas_menu /etc/init.d/S99adas_menu
chmod +x /etc/init.d/S99adas_menu
```

`S99adas_menu` 负责使能 PCIe 端点、等待 FPGA 版本就绪，然后拉起 `run_boot.sh`；`run_boot.sh` 先调 `mode_select` 显示开机二选一，再按选择启动 `menu_daemon`（FPGA 实时画面）或 `usb_menu`（U 盘素材浏览）。

### 步骤 4：自检

```sh
python tools/selftest.py            # 交叉编译 + 脚本语法 + 文档不变量 + 资产完整性
python tools/rk_diag.py <板卡IP>     # 现场体检：PCIe 端点/速率/带宽、固件版本、显示状态、进程
```

`selftest.py` 退出码 0 表示全部通过；`rk_diag.py` 任一项失败返回 1，并打印具体寄存器值（BAR1 `0x838` 版本、`0x800` 显示主控、`0x82C` 欠载计数）。

## 四、移植到其他板卡

本工程与具体板卡的绑定集中在三处，换板只需改这三处：

| 绑定项 | 位置 | 说明 |
| --- | --- | --- |
| 管脚与电平 | `fpga/pnr/pango_pcie_top.fdc` | PCIe、DDR3、HDMI、摄像头、按键的全部引脚约束 |
| 顶层与 IP 配置 | `fpga/pnr/pg2l_pcie_dma.pds`、`fpga/ip/` | 器件型号、PCIe IP（Gen2 x2）、DDR3 位宽与容量 |
| 板端地址与版本 | `tools/menu/run_boot.sh`、`tools/usb_feed/usb_feed.c` | BAR1 基址 `0xf0204000`、固件版本 `0x20261106`、设备号 `0002:21:00.0` |

同类器件（同封装、同 DDR3 位宽）更换板卡时，改完 `.fdc` 后按步骤 1 重建位流即可；若 DDR3 或 PCIe 通道数变化，需同步调整 `fpga/ip/` 内的 IP 参数与顶层例化。

## 五、常见问题

1. **PDS 打开工程报找不到源文件**：确认是从 `fpga/pnr/pg2l_pcie_dma.pds` 打开（工程内为 `../src/...` 相对路径），不要单独拷贝 `.pds`。
2. **`tools/rk_build.sh: zig not found`**：安装 Zig 0.14.1 并加入 PATH，或用 `ZIG=` 指定可执行文件。
3. **板端起不来、`/tmp/run_boot.log` 记录 `mode_select failed 3x`**：先 `python tools/rk_diag.py` 查 PCIe 枚举与固件版本，再确认 `/userdata/quad/menu/` 素材齐全。
4. **HDMI 黑屏**：确认位流为 cam23（`0x838 = 0x20261106`），并检查 `0x800` 显示主控寄存器。
5. **NPU 初始化失败**：确认 `/userdata/quad/b5_v6n_band.rknn` 存在，板端 `librknnrt` 为 1.5.0（`strings /usr/lib/librknnrt.so | grep -i version`）。

## 六、随包文档

| 文件 | 内容 |
| --- | --- |
| `docs/submit/BUILD.md` | 各模块构建命令与源码清单 |
| `docs/submit/DEPLOY.md` | 板端部署、开机脚本、Flash 固化、故障排查 |
| `docs/submit/THIRD_PARTY.md` | 第三方组件来源与许可证 |
| `README.md` | 系统架构与仓库总览 |
