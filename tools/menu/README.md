# tools/menu — 板载人机交互与启动系统

RK3568 用户态程序，全部只用 libc + 直接 mmap BAR1，不依赖 Qt/GTK/DRM。四个可执行文件：

| 文件 | 作用 | 关键行为 |
|---|---|---|
| `mode_select.c` | 开机二选一界面 | 推 4 格预渲染素材；KEY0 切换、KEY1 返回 `0`/`1`；KEY4 长按退出（rc=2）；推图前等 DMA 静止并重试 3 次 |
| `menu_daemon.c` | 实时四路 + 弹窗 | 拉起 `usb_feed`（3 路 USB）；KEY4 短按弹窗、长按退出回选择界面；子进程按进程组回收 |
| `usb_menu.c` | U 盘浏览器 + 播放 | 中文文件名（GBK 位图字库）、按顺序选 1–4 个 mp4/图片、播放弹窗、`--dec-bufs` 自适应 |
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

| 键 | 短按 | 长按 1–3 s | 按住 3 s |
|---|---|---|---|
| KEY0 | 光标/车道循环 | — | — |
| KEY1 | 确认/启停 | — | — |
| KEY2/3 | 转向请求 | 强制变道 | — |
| KEY4 | 弹窗开关 | 退出/切源 | 进 cal_mode（避免） |

菜单占用 KEY0/KEY1，因此 ADAS 侧用基线抵消（`adas.c` 的 `g_lane_base`/`g_moving_base`）。
寄存器细节见技术报告附录 A。

## 已知边界

- 静态图片解码走板端 GStreamer `decodebin`，未上板验证；
- `usb_menu` 的 SIGUSR1 基线重置已接入但未实测；
- 返回选择界面的 DMA 卡死已从进程回收/等待/重试三处加固，待上板复测。
