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

在板端 `/etc/init.d/S99adas_menu` 写入以下内容（`chmod +x`）：

```sh
#!/bin/sh
case "$1" in
  start)
    echo "Starting ADAS Menu Daemon..."
    killall weston 2>/dev/null || true
    E=/sys/bus/pci/devices/0002:21:00.0
    if [ -e "$E" ]; then
        echo 1 > "$E/enable"
        printf '\006' | dd of="$E/config" bs=1 seek=4 count=1 conv=notrunc 2>/dev/null
    fi
    cd /userdata/quad && /userdata/quad/run_boot.sh &
    ;;
  stop)
    killall usb_feed menu_daemon usb_menu mode_select 2>/dev/null || true
    ;;
  restart)
    $0 stop
    sleep 1
    $0 start
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
    exit 1
    ;;
esac
exit 0
```

## 三、FPGA Flash 固化步骤

参考 `FPGA_flash固化方案_20261018.md` 规范：
1. **生成 SFC 镜像**：利用 PDS 工具 `cfg_gen_sfc` 将 `quad_cam11.sbit` 转换为 `quad_cam11.sfc`（默认单线 Fast Read 0x0B，起始地址 0x0）。
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
