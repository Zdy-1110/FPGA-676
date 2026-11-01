# tools/menu — 板载人机交互与启动系统

RK3568 用户态程序，全部只用 libc + 直接 mmap BAR1，不依赖 Qt/GTK/DRM。四个可执行文件：

| 文件 | 作用 | 关键行为 |
|---|---|---|
| `mode_select.c` | 开机二选一界面 | 推 4 格预渲染素材；KEY0 切换、KEY1 返回 `0`/`1`；KEY4 长按退出（rc=2）；推图前等 DMA 静止并重试 3 次；写 `0x800=0x865`（`0x65 + NIGHT OFF`）防止暗底 UI 被 AUTO 误判夜间 |
| `menu_daemon.c` | 实时四路 + 弹窗 | 拉起 `usb_feed`（3 路 USB）；KEY4 短按唤出 9 项 3×3 弹窗（CAM1、CAM2、CAM3、NPU、LANE、VIEW、ZEBRA、USB VIDEO、NIGHT），长按退出回选择界面；子进程按进程组回收 |
| `usb_menu.c` | U 盘浏览器 + 播放 | 中文文件名（GBK 位图字库）、按顺序选 1–4 个 mp4/图片；列表界面写 `0x800=0x865`（`0x65 + NIGHT OFF`）；播放唤出 5 项弹窗（NPU、LANE、VIEW、ZEBRA、NIGHT）、`--dec-bufs` 自适应 |
| `menu.c` | 推图/OSD/按键参考实现 | 被上述程序复制的 DMA/OSD 函数原型 |

启动链：

```
/etc/init.d/S99adas_menu  (守护循环)
  └─ run_boot.sh           (等 0x838 就绪；mode_select 失败重试 3 次)
       └─ mode_select      (rc 0=实时, 1=U盘, 2=用户退出)
            ├─ menu_daemon
            └─ usb_menu
```

## 编译

```sh
sh tools/rk_build.sh tools/menu/menu_daemon tools/menu/menu_daemon.c -lpthread
sh tools/rk_build.sh tools/menu/mode_select tools/menu/mode_select.c
sh tools/rk_build.sh tools/menu/usb_menu   tools/menu/usb_menu.c
```

`--still` 图片输入由 `tools/usb_feed` 提供；`usb_menu` 按后缀自动分派 `--video` / `--still`。

## 运行时资源

| 路径 | 内容 |
|---|---|
| `/userdata/quad/menu/tile0-3.*` | 四路实时四格素材（`tile0.rgb565` + `tile1-3.nv12`） |
| `/userdata/quad/menu/sel0-3.*` | 二选一界面四格素材 |
| `/userdata/quad/ui_cjk.bin` | GBK 字库（21,791 字，26×26，2.33 MB） |

素材由 `gen_tiles.py` / `gen_selector.py` / `gen_cjk_font.py` 生成。

## 按键（FPGA 侧，0x844 / 0x848）

| 键 | 短按 | 长按 1–10 s | 按住 10 s |
|---|---|---|---|
| KEY0 | 光标/车道循环 | — | — |
| KEY1 | 确认/启停 | — | — |
| KEY2/3 | 转向请求 | 强制变道 | — |
| KEY4 | 弹窗开关 | 3 s 退出/切源 | 10 s 进 cal_mode（避免） |

菜单占用 KEY0/KEY1，因此 ADAS 侧用基线抵消（`adas.c` 的 `g_lane_base`/`g_moving_base`）。
寄存器细节见技术报告附录 A。

## 弹窗与夜间增强交互 (NIGHT)

- **实时模式弹窗（9 项 3×3 布局）**：
  - 布局：
    - 行 1：CAM1、CAM2、CAM3
    - 行 2：NPU、LANE、VIEW（COLOR / GRAY / BIN 循环）
    - 行 3：ZEBRA、USB VIDEO、NIGHT
  - KEY0 移动光标（0–8 循环），KEY1 执行/切换项；短按 KEY4 开关弹窗，长按退出回选择界面。
- **U 盘播放弹窗（5 项布局）**：
  - 项包含：NPU、LANE、VIEW、ZEBRA、NIGHT。
- **NIGHT 控制逻辑**：
  - 按 KEY1 循环切换：`AUTO` (0) → `ON` (1) → `OFF` (2) → `AUTO` (0)，对应写 `0x800[11:10]`。
  - 在 `AUTO` 模式下，若 FPGA 硬件当前判定达到暗光阈值并正在执行增强（读 `0x820` bit3 `night_active == 1`），文本动态显示为 `AUTO*`，未触发时显示 `AUTO`。
- **UI 界面 0x865 配置原因**：
  - 开机模式选择界面（`mode_select`）和 U 盘文件列表界面（`usb_menu`）统一向 `0x800` 写入 `0x865`（即 `0x65` 通路配置 + `[11:10]=10` NIGHT 强制 OFF）。
  - 原因：选择界面和文件列表均为深色/暗底 UI，若置于 `AUTO` 模式会被 FPGA 统计平均亮度误判为夜间暗光场景而误触发 gamma 增强，导致界面发灰变白；因此在 UI 停留期间强制写入 `0x865`（NIGHT OFF），进入实际播放或实时画面时再恢复为 `AUTO`。

## 已知边界

- 静态图片解码走板端 GStreamer `decodebin`，已于 10-30 完成板端实测验证（静态图片推流与按键基线，详见 `docs/提交清单与待办.md:21-31`）；
- `usb_menu` 的 SIGUSR1 基线重置已接入但未实测；
- 返回选择界面的 DMA 卡死已从进程回收/等待/重试三处加固，待上板复测。
