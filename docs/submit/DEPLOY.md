# 系统部署与运行说明 (DEPLOY)

本文件说明板端运行环境布置、开机脚本配置、FPGA Flash 固化步骤及常见故障排查。

## 一、板端目录 `/userdata/quad/` 部署文件

板端部署需要将下列二进制及资源拷贝至 `/userdata/quad/` 目录下并赋予执行权限：
1. `usb_feed`: 主数据流转发与 ADAS 综合处理可执行文件
2. `usb_menu`: 车载触控/按键交互控制终端
3. `mode_select`: 启动模式选择器
4. `menu_daemon`: 菜单后台监听守护进程
5. `run_boot.sh`: 引导控制脚本（见 `tools/menu/run_boot.sh`）
6. `b5_v6n_band.rknn`: NPU INT8 交通目标识别模型
7. `ui_cjk.bin`: 汉字与 ASCII 点阵字体文件
8. `menu/`: 菜单背景与选框素材目录，包含 `tile0-3.*` 与 `sel0-3.*` 图素

## 二、开机启动脚本 `/etc/init.d/S99adas_menu`

仓库内提供 `tools/menu/S99adas_menu`（POSIX sh），部署到板端并加执行权限：

```sh
cp tools/menu/S99adas_menu /etc/init.d/S99adas_menu
chmod +x /etc/init.d/S99adas_menu
```

与早期版本相比，它增加了一层**守护循环**：`run_boot.sh` 连续三次 `mode_select` 失败退出后，脚本会在 1 s 后重新拉起整条链路，避免现场停留在半幅画面或黑屏；每次退出的返回码与时间都会追加到 `/tmp/run_boot.log`。

要点：
- PCIe 端点使能（`enable=1` + 写 Command 寄存器）由 `run_boot.sh` 负责，S99 不重复；
- 若板端启用了 Weston 桌面，可在 `start)` 前加 `killall weston 2>/dev/null || true` 释放显示资源（本项目不依赖 DRM）；
- `stop)` 会清理 `run_boot.sh`、`mode_select`、`menu_daemon`、`usb_menu`、`usb_feed` 全链路进程。


## 三、FPGA Flash 固化步骤

参考 `FPGA_flash固化方案_20261018.md` 规范：
1. **生成 SFC 镜像与烧录脚本**：利用 PDS 工具 `cfg_gen_sfc` 将 `quad_cam18.sbit` 转换为 `quad_cam18.sfc`（默认单线 Fast Read 0x0B，起始地址 0x0），并引用 `tools/flash/flash_program_cam18.tcl` 自动化执行 Flash 擦除、编程与校验。
2. **安全断开 PCIe 链路**：在 RK3568 端移除 EP 设备 `0002:21:00.0` 并设置根端口链路禁用，防止烧写期间总线操作引发 SoC 挂死。
3. **识别 Flash 型号**：通过 Fabric Configuration 的 JTAG 间接烧写扫描识别 SPI NOR Flash（如 W25Q128JV 或芯天下 XT25BF128F）。
4. **擦除与编程**：执行 Flash 擦除（Auto 范围），烧录 SFC 固化镜像并执行 Verify 校验。
5. **恢复与冷启动**：整机断电后重新上电，FPGA 在约 1.2 秒内自加载就绪，RK3568 引导完成 PCIe 5.0 GT/s 链路建立。

## 四、系统启动顺序

1. 上电冷启动：盘古 100Pro+ 与 OK3568 同时供电，FPGA 从 Flash 自加载比特流完成配置。
2. 内核引导：RK3568 内核启动，自动枚举 P29 槽位的 PCIe Gen2 x2 EP 设备。
3. 设备初始化：`S99adas_menu` 脚本自动使能 EP 并置位 Command 寄存器 Bus Master 与 Memory Space。
4. 应用层运行：引导拉起 `run_boot.sh`，呈现启动菜单并运行 ADAS 决策主任务。

## 五、故障排查指南 (5 条)

1. **PCIe 链路未识别**：`lspci` 未见 `0002:21:00.0`。检查 P29 槽位金手指物理连接，确认 FPGA 已加载有效位流且 DONE 引脚拉高。
2. **BAR1 空间读写异常**：`devmem` 提示 Bus error。检查是否执行 `echo 1 > enable`，以及是否向 PCIe 配置空间写入 `0x06` 开启总线主控。
3. **USB 摄像头采集失败**：`/dev/video*` 无法打开。检查 USB HUB 供电，用 `lsusb` 验证设备节点与分辨率支持格式。
4. **NPU 模型初始化失败**：`rknn_init` 报错。检查 `/userdata/quad/b5_v6n_band.rknn` 路径与权限，确认 NPU 驱动版本与 librknnrt 版本匹配（1.5.0）。
5. **HDMI 画面黑屏或无信号**：检查板载 MS7210 芯片供电与 HDMI 显示线缆连接，读取 BAR1 寄存器 `0xf0204850` 确认帧率状态。
