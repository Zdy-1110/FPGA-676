# PCIe x2 提速攻坚 — 进度与交接文档

> 更新：2026-10-05 深夜（第 2 版）
> 目标：RK3568（飞凌 OK3568-UP4）+ 盘古100Pro+ FPGA 卡的 PCIe 链路提速，Gen1 x1（≈250MB/s）→ Gen2 x2（≈1GB/s）
> **★ 状态：目标已达成** —— 启动修复 + P29 槽 Gen2 x2 链路 + DMA 数据面往返验证全部通过；唯一剩余阻塞是"官方 .ko 驱动编译缺 5.10.160 内核源码树"。
> 本文档汇总已破案的结论、当前硬件/软件状态、未解决问题与后续路线，供后续会话直接续接。

---

## 一、当前状态快照（重要，接手先看）

| 项 | 状态 |
|---|---|
| FPGA 卡位置 | **P29 槽（PCIE_A，x2）**，已实测协商 **Gen2 x2 = 5.0GT/s × 2**（≈1GB/s） |
| FPGA 配置 | **x2 比特流已烧、done bit=1、正在运行**。⚠️**SRAM 掉电即丢——别给 FPGA 板断电**；断电后需按 §3.3 重烧 |
| RK 板子状态 | **已修复、能正常 autoboot 进 Linux**（Buildroot 登录），PCIe 枚举正常 |
| boot 分区 DTB | ★已用 recovery 分区内的原版 DTB 修回，读回 CRC32=`74a6f13e`（= FIT 期望的 sha256 `c589cc9b`） |
| DMA 数据面 | ★**已用 devmem 直控 BAR1 验证**：128B 逐字比对 + 4096B 满包往返全一致（§2.7） |
| 官方驱动 .ko | ⛔**未编译**：需 5.10.160 内核源码树；F 盘已断开、本机无 SDK（§4.4） |
| 串口 | COM14（XR21 Ch A，115200），pyserial 直连，root/root |
| JTAG 调试器 | FT2232H 双通道，**本次枚举为 COM15/COM16**（不是 3/4；拔插后编号会变，以实际为准） |

---

## 二、已完成的工作

### 2.1 ★x2 提速根因破案

**`NUM_OF_LANES` 是 bool 型标志位**（x4 官方工程也是 `5'b1`），之前三轮实验把它改成 `5'b10/5'b11` 全是非法值 → 控制器 lane 逻辑崩 → LTSSM 卡 Detect。真正决定 lane 数的是三个参数：

| 参数 | 作用 | x1 值 | **x2 值** |
|---|---|---|---|
| `MAX_LINK_WIDTH` | enum 1/2/4 = x1/x2/x4 | `6'd1` | **`6'd2`** |
| `LINK_CAPABLE` | DWC 枚举 1/3/7 = x1/x2/x4 | `6'd1` | **`6'd3`** |
| `NUM_OF_LANES` | **bool 标志，不能动** | `5'b1` | `5'b1`（保持） |
| `HSST_LANE_NUM` | PHY lane 数 | 1 | **2** |

**破案途径**：F 盘 50K 板资料 `PCIE资料\pcie_test_platform_v1_0(1).zip` 内藏官方 Gen2 x4 完整工程 `pcie_test_rtl\PG2L100H_PCIe_performance`（与 4_15 同套 RTL），其参数就是标准答案。

### 2.2 x2 比特流编译并烧写验证成功

- EP 广告正确：x2 sbit 烧好后 EP sysfs `max_link_speed=5.0 GT/s、max_link_width=2`。
- 网表验证法：`grep GTP_HSST_2LANE_TOP` 网表（x2 应为 2LANE_TOP）+ map 报告 `GTP_HSSTLP_LANE 2 uses`。
- 产物：`D:\pango_work\pango_pcie_dma_x2.sbit`（3,791,112B）；x1 备份 `pango_pcie_dma_x1_backup.sbit`。

### 2.3 PDS 命令行全自动编译链打通

`pds_shell` 全流程（compile → synthesize → dev_map → pnr → gen_bit_stream）约 2.5 分钟，改比特流→上板验证一轮约 10 分钟。详见 §3.2 的深坑说明（compile DB 缓存、IP 的 FILE 登记机制）。

### 2.4 U-Boot 恢复流程打通（已实战验证）

FIT/DTB 写坏后可完全救回：维护菜单 → U-Boot shell → `mmc read/write` 直接修（本地法，见 §2.6）或静态 IP + 单端口 TFTP 从 PC 传（§3.6）。

### 2.5 PCIe IP 模型结论

PCIe IP 模型（.iar）**不随 PDS 主安装器发布**：官网 pangomicro.com 无 PCIe IP、下载需会员登录；要 1.2c 只有 PDS SP6.1 之前的安装器；要 1.4/1.5/1.6 需官网会员或 FAE。装模型方法：IP Compiler GUI 里 File→Update→Add Package→选 .iar→Install。本次靠官方 x4 参考工程绕过了对 IP Compiler 的需求。

### 2.6 ★2026-10-05 深夜：RK 启动修复（FIT/DTB 破案 + recovery 分区自带原版 DTB）

**卡点现象**：autoboot 到 `boot_fit` 时 fdt 节点 sha256 校验失败（期望 `c589cc9b` 实际 `1be806ba`）→ `FDT and ATAGS support not compiled in - hanging` + `### ERROR ###`。这是 U-Boot `panic()` 的死循环，**串口对任何输入都无响应，只能物理复位**。

**关键发现**：板上 boot 分区那份 DTB 与 `dtb_orig.bin`/`dtb_new.bin` 都对不上（来历不明的残留版本）；而 **recovery 分区（LBA 0x28000）+0x800 偏移处存着一份完好原版 DTB**——112,563B，CRC32 = `74a6f13e`，与 FIT 期望哈希完全一致。因此**无需从 PC 传任何文件**，纯本地即可修复。

**修复命令（全部只用 0x08300000 缓冲区，已在真板验证）**：

```uboot
mmc dev 0
mmc read 0x08300000 0x28004 0xDC      # 从 recovery 分区读原版 DTB
crc32 0x08300000 0x1B7B3              # 期望 74a6f13e
mmc write 0x08300000 0x8004 0xDC      # 写回 boot 分区 DTB 位置
mmc read 0x08300000 0x8004 0xDC
crc32 0x08300000 0x1B7B3              # 再验一次 74a6f13e
```

之后 `reset` → 完整启动到 Linux 登录 ✓。（顺带覆盖的 77 字节是 FIT 两个 blob 之间的对齐填充，不参与任何哈希）

**定位/取证用的关键指纹**：工厂 DTB（`dtb_orig.bin`）sha256 = `c589cc9b4097...`、crc32 = `74a6f13e`；事件前板上那份坏 DTB crc32 = `cd866dfb`。

### 2.7 ★★2026-10-05 深夜：P29/PCIE_A 槽 Gen2 x2 链路 + DMA 数据面验证（目标达成）

- 卡插 **P29（3c0800000.pcie / fe280000）**，x2 比特流烧好后 RK 启动即：`PCIe Link up, LTSSM is 0x130011` → `PCI host bridge to bus 0002:20`，EP = **`0002:21:00.0` 0755:0755**，sysfs `current_link_speed=5.0 GT/s PCIe`、`current_link_width=2` → **Gen2 x2 ≈ 1GB/s 达成**。
- 另一控制器 `3c0000000.pcie`（P30）无卡：`PCIe Link Fail`，符合预期。
- **纠正旧结论**：旧版 §4.2 判定"P29 链不起来 = DT 缺 pipe-grf"——**不成立**。P29 实际能正常训练（dmesg 里 `rockchip-snps-pcie3-phy fe8c0000.phy: failed to find rockchip,pipe_grf regmap` 只是无害警告）。**之前 P29 失败的真因是 FPGA 未配置 / 未在 RK 启动前加载好**。路线 B（改 DTS 重打包）因此**不再是 P29 提速的必要条件**。
- **无驱动也能验证数据面（devmem 直控 BAR1，本次实测路径）**：
  1. `echo 1 > /sys/bus/pci/devices/0002:21:00.0/enable` —— **必须**！否则 COMMAND 寄存器 Memory Space Enable=0，读 BAR 全 `0xFFFFFFFF`；
  2. DMA 寄存器在 BAR1（本次映射 **0xf0204000**，4KB）：
     - 写向（主机→FPGA RAM）：`0x100/0x104`(MEM 地址低/高) `0x110`(FPGA RAM 偏移) `0x120`(长度 = 字节/4 - 1) `0x140`(地址类型 0=32位) → 轮询 `0x130`==1；
     - 读向（FPGA RAM→主机）：`0x200/0x204/0x210/0x220/0x240` → 轮询 `0x230` 非零；
  3. DMA 缓冲区用 **ramoops 保留区 0x110000**（/dev/mem 可访问；0x08300000 那块被 /dev/mem 拒；**dd 读写 /dev/mem 会报 Bad address，只能 devmem 逐字**）；目标缓冲用 0x111000；
  4. 结果：128B 逐字（`0x10000000+i`）与 4096B 满包（跨段 15 点采样）**A/B 全一致**，两方向 done 位均置 1。

### 2.8 官方驱动的现状与阻塞

`4_15_PCIE_DMA\linux\` 里预编译的 `.ko` 与测试程序都是 **x86-64**（vermagic 4.15.0-91），**不能**在 RK3568 上用；必须在 5.10.160 内核树里重编（aarch64）。板端 `/lib/modules/5.10.160/build` 是指向构建机的悬空软链接、且无 gcc → 不能在板上编。**需要飞凌 SDK/内核源码树**（F 盘目前断开，`D:\pango_work\ksrc` 为空）。

---

## 三、关键技术档案

### 3.1 x2 改造的具体文件与改动

工程：`D:\pango_build\4_15_PCIE_DMA\`（x2 改造版，top = `pango_pcie_dma_top`）

| 文件 | 改动 |
|---|---|
| `ip\PCIe_IP\PCIe_IP.v` | L159 `MAX_LINK_WIDTH=6'd2`、L163 `LINK_CAPABLE=6'd3`、L169 `NUM_OF_LANES=5'b1`（不动）、L340 `HSST_LANE_NUM=2` |
| `ip\PCIe_IP\rtl\ips2l_pcie_top_v1_2c.v` 等同目录 4 个文件 | 默认参数同步改为 x2（WIDTH=`6'b00_0010`、CAPABLE=`6'b00_0011`、HSST_LANE_NUM=2） |
| `pnr\pg2l_pcie_dma.pds` | ① 插入 55 个 FILE item（`ip/PCIe_IP/PCIe_IP.v` + `rtl/**` + 4 个 ram IP 的 .v，format="systemverilog"）② 删除 PCIe_IP 的 `type="IP"` 条目 |
| `pnr\pango_pcie_top.fdc` | gen2x4 分支的 5 行 `define_attribute` 已加 `#` 注释，gen2x2 分支生效（PAP_LOC 同一个 quad 364_918） |

编译脚本 `D:\pango_build\4_15_PCIE_DMA\pnr\build_x2.tcl`：

```tcl
open_project D:/pango_build/4_15_PCIE_DMA/pnr/pg2l_pcie_dma.pds
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
compile -top_module pango_pcie_dma_top -force_to_run     ;# ★必须，见 §3.2 坑1
synthesize -ads -selected_syn_tool_opt 2 -force_to_run
dev_map -force_to_run
pnr -planning_before_place Enable -force_to_run          ;# 2025.2 合法值 Enable/Disable/Auto
report_timing
gen_bit_stream -master_configuration_clock_frequency {25M} -force_to_run
```

运行方式：`pds_shell -file build_x2.tcl -work_dir <可写目录>`（产物在 work/prj_tasks/... 下，取出后拷到 D:\pango_work）。

### 3.2 PDS 编译深坑（前几轮实验失败的元凶）

1. **compile DB 缓存**：`pds_shell` 的 synthesize 读 compile DB（日志 "Reading design from compile DB"），**改源码后 DB 不刷新** → 必须 `compile -top_module <top> -force_to_run`。而 compile 要求 IP RTL 以 FILE 形式登记在 .pds 里（见上表 pds 文件的两处手工修改）。改完还要删 `prj_tasks` 清缓存。
2. **INVALID 的 IP 条目会阻止展开**（报 Verilog-4072 undefined module）→ 必须 FILE 注册 + 删 IP 条目。
3. **python re.sub 的 raw replacement 陷阱**：`r"...\'..."` 会把反斜杠写进文件（`6\'b` 非法语法 → 文件被解析器拉黑静默跳过）。改 .v 文件用 Edit 工具或纯数字字符串替换。
4. **fdc 分支必须与 RTL 一致**：x2 网表下 `.x4.` 层次不存在，fdc 的 gen2x4 `define_attribute` 报 ConstraintEditor-0046 失败 → 注释掉。
5. 2022.2 旧工程 DB 与 2025.2 不兼容 → 删 `prj_tasks` 后 PDS 会把 .pds 重写为 2025.2 原生。

### 3.3 FPGA 烧写（JTAG，无需 GUI）

```powershell
# ① 起烧写服务器（PowerShell；cmd start 不生效）
Start-Process -FilePath "D:\pango_pds\bin\cdt_js.exe" -ArgumentList "-port","65421" -WorkingDirectory "D:\pango_pds\bin" -WindowStyle Minimized
# ② 执行 tcl（PDS 安装目录 bin\cdt_cfg_shell.exe）
& "D:\pango_pds\bin\cdt_cfg_shell.exe" -work_dir "D:\pango_work" -file "D:\pango_work\prog_x2.tcl"
```

- `prog_x2.tcl`：`cfg_connect -ip 127.0.0.1 -port 65421` → `cfg_scan_chain` → `cfg_assign_file -file D:/pango_work/pango_pcie_dma_x2.sbit -device_index 0` → `cfg_program` → `cfg_close`
- `prog_x1.tcl` 同流程烧 x1 备份；`check.tcl` 只连+扫链（确认 `PG2L100H` 与 `done bit: 1`）。
- 调试器是 **FT2232H**（本次 COM15/COM16），别与 UP4 的 XR21（COM11-14）混淆。
- 服务器偶发假死，重开即可。sbit 必须放纯 ASCII 路径。
- 日志：`D:\pango_work\configuration_tcl.log`（cfg_* 每步结果）；工具自身写 `E:\Project\nesai2026\log\cfg.log` 会因中文路径报 "Unable to open file"（无害，可忽略）。

### 3.4 UP4 板两个 PCIe 槽位（实测确认）

| 槽 | 规格 | RK 控制器 | DT 节点 | 实测 |
|---|---|---|---|---|
| **P29** | PCIe3.0 x2（物理 2 lane，丝印/信号名 PCIE_A） | `fe280000` = `3c0800000.pcie` | `max-link-speed=3`，`num-lanes=2` | ★插 FPGA 卡后 **Gen2 x2 链路 OK** |
| **P30** | PCIe2.1 x1（物理 1 lane） | `fe260000` = `3c0000000.pcie` | — | 空槽时 `Link Fail`（预期） |

- P29 实测上限：**Gen2 x2 ≈ 1GB/s** 已达成（硅是 PCIe3，改 DT `max-link-speed` 理论可试 Gen3，未做）。
- **RK 上电只探测一次 PCIe**：FPGA 必须在 RK 启动前加载好（JTAG 烧好后再让 RK 启动/`reboot`，FPGA 供电不断配置不丢；或固化 sfc 后同插排上电）。
- 板卡**独立供电**（插槽带不动），两板插同一插排同时上电。

### 3.5 boot 分区结构与 FIT

- boot 分区 = `/dev/mmcblk0p3`（GPT LBA 0x8000–0x27FFF，64MB）：开头 1536B 是 **Rockchip external-data FIT 头 DT**（各 blob 的 data-position 指明偏移），**内核 DTB 位于偏移 0x1000800（= 16MB+2048B = 扇区 0x8004），112,563 字节**（`forlinx,ok3568`）。
- 完整分区表（实测）：p1 uboot 0x4000、p2 misc 0x6000、p3 boot 0x8000、p4 recovery 0x28000、p5 backup(全零) 0x68000、p6 rootfs 0x78000、p7 oem 0xC78000、p8 userdata 0xCB8000。
- FIT 头带 **sha256 + rsa2048 签名节点**；`## Verified-boot: 0`（安全启动关闭）时仍会逐 blob 校验 sha256，fdt 坏了就 `panic` 挂死。
- **★recovery 分区 +0x800 处有原版 DTB 副本**（crc32 74a6f13e，见 §2.6）——修 DTB 的本地素材来源。
- DTB 读写（U-Boot，单位是**扇区**）：
  ```
  mmc read 0x08300000 0x8004 0xDC    # 读 220 扇区 = 112,640B（覆盖 112,563B DTB）
  mmc write 0x08300000 0x8004 0xDC   # 写回
  ```
- ⚠️ **U-Boot 数字参数全部按十六进制解析**：`mmc write 32772 ...` 会被当成 0x32772=206706 写到错误地址。
- ⚠️ **U-Boot 缓冲区地址别用 0x09000000**（TrustZone/OP-TEE 保护区，CPU 访问即 Data Abort → panic）；**一律用 0x08300000**。
- 挂死后救法：物理复位，维护菜单选 `0: Exit to console` 进 U-Boot shell（或提前挂 `catch_uboot_shell.py` 自动接管，见 §6）。

### 3.6 U-Boot 单端口 TFTP 流程（PC→板传文件用；已验证，但注意地址）

```uboot
# U-Boot 侧（网线直连 PC，PC 用 APIPA 地址 169.254.33.151）
setenv ipaddr 169.254.33.200; setenv netmask 255.255.255.0
setenv serverip 169.254.33.151
tftpboot 0x08300000 <file>          ;# ★0x08300000，别用 0x09000000
mmc write 0x08300000 8004 dc
```

```bash
# PC 侧（D:\pango_work\tftp\single_port_tftp.py，root 目录 = 脚本所在目录）
python single_port_tftp.py
```

⚠️ **必须用单端口 TFTP**（数据也从 69 端口发）：U-Boot 只认源端口 69 的数据包。MobaXterm/Windows 防火墙若拦，先放行 python。

### 3.7 串口与文件传输

- **pyserial 直连 COM14**（115200，root/root 登录）替代 MobaXterm 全自动收发。XR21 驱动句柄可能卡死（PermissionError 13）→ 拔插 USB 恢复；MobaXterm 会独占串口，用 pyserial 前先杀掉它。
- PC→板小文件：板上 `cat > file` + 分块回显流控（~14 秒/150KB）；板→PC：板上 `base64 file` 输出、PC 端 pyserial 接收解码。
- 板上 `/tmp` 的操作文件断电即丢，PC 端备份是唯一持久副本。
- **本板 U-Boot 没有 `loadx/loady/loadb`**（串口 XMODEM 传文件方案不可用）；串口传文件只能在 Linux 侧做。

---

## 四、问题状态

### 4.1 ✅ 已解决：autoboot（原 P0）
见 §2.6。boot 分区 DTB 已由 recovery 分区原版修补，读回校验一致，实测完整启动进 Linux。

### 4.2 ✅ 已解决/已纠正：P29 槽链路（原 P1）
见 §2.7。P29 现稳定 Gen2 x2。旧判断（"DT 缺 pipe-grf 导致 P29 链不起来"）**不成立**：真因是当时 FPGA 未配置/未在 RK 启动前加载。`fe8c0000.phy ... failed to find rockchip,pipe_grf regmap` 是无害警告，**暂无需改 DTS 重打包**。

### 4.3 ✅ 已解决：DMA 数据面（原 P2）
见 §2.7。devmem 直控 BAR1 完成双向 + 4096B 满包往返数据一致性验证。

### 4.4 ⛔ 当前唯一阻塞：官方 .ko 驱动编译缺内核源码
- 需要 **OK3568 Linux 5.10.160 内核源码树** + aarch64 交叉工具链，才能编 `pango_pci_driver.ko`、`dma_pio_app`、`pio_test`（板端无 gcc、无内核头）。
- 现状：**F 盘（`F:\BaiduNetdiskDownload`）已断开**，`D:\pango_work\ksrc` 空；飞凌源码包此前记录为损坏（需重下）。
- 拿到源码后：`make -C <kernel_src> M=<linux/driver> ARCH=arm64 CROSS_COMPILE=<aarch64-...-> modules` → 上传 → `insmod` → 跑官方测试。

---

## 五、后续路线图

### ✅ 已完成（原路线 A 的升级版，无需换槽、无需 PC 传文件）
本地修 DTB（§2.6）→ P29 上 Gen2 x2 链路（§2.7）→ devmem 验证 DMA 数据面（§2.7）。

### 当前正路：编译官方驱动 + 跑 RD04005 官方测试，拿实测吞吐
1. 拿到 5.10.160 内核源码树 + aarch64 工具链（§4.4）
2. 编 `pango_pci_driver.ko` 与 `dma_pio_app`/`pio_test`（`linux/driver/Makefile`、`linux/Makefile`）
3. 板上 `insmod pango_pci_driver.ko` → `./pio_test 0xa`（BAR0 读写）→ `./dma_pio_app -d 1000 -l 4096`（DMA 往返 + 计时）
4. 记录实测吞吐，作为 x2 提速的最终数字

### 路线 B（已降级，非必需）：改 DTS 重打包镜像
仅当还要动 RK 侧 PCIe DT（如试 Gen3 `max-link-speed=3`）时才需要；P29 链路本身已通。⚠️ `1-源码分卷包已损坏`（百度网盘零块坑，需重下）。

### 路线 C（救急手段，已验证）：U-Boot TFTP / MaskROM 全刷
- U-Boot 可用 → §3.6 流程（注意别用 0x09000000 加载地址）
- U-Boot 都进不去 → MaskROM + RKDevTool 全刷（`update.img` 在 F 盘，需先挂回）

### 顺手清理项
- `D:\pango_2022` 残骸（4.7GB 半安装）、`D:\pango_work\setup2022`、`D:\pango_work\ksrc`（空）

---

## 六、文件与工具清单

### FPGA 工程/产物
| 路径 | 说明 |
|---|---|
| `D:\pango_build\4_15_PCIE_DMA\` | x2 改造版 DMA 工程（改动见 §3.1） |
| `D:\pango_work\pango_pcie_dma_x2.sbit` | ★x2 比特流（3,791,112B，现已在 FPGA 里跑着） |
| `D:\pango_work\pango_pcie_dma_x1_backup.sbit` | x1 备份比特流 |
| `D:\pango_work\pango_pcie_dma_top.sbit` / `pango_pcie_top.sbit` | 官方预编译（2_13/4_15） |
| `D:\pango_work\prog_x2.tcl` / `prog_x1.tcl` / `check.tcl` | JTAG 烧写脚本（§3.3） |
| `D:\pango_build\4_15_PCIE_DMA\linux\` + `docs\RD04005...pdf` | DMA 驱动源码 + 使用说明（当前正路用） |
| `E:\Project\nesai2026\pcie_demo\` | 2_13 枚举测试 + 4_15 DMA 例程解压处 |

### 本次新做的自动化脚本（都在 D:\pango_work）
| 路径 | 说明 |
|---|---|
| `catch_uboot_shell.py` | ★复位后自动打断 autoboot → 维护菜单选 0 → 落 U-Boot shell（20 分钟窗口；靠 Ctrl+C 流打断倒计时） |
| `uboot_cmd.py` | U-Boot 批执行命令（参数用 `\|` 分隔；会等 `=>` 回来） |
| `uboot_reset_capture.py` | `reset` 并抓启动日志到 `boot_after_fix_raw.bin`，判到 login/失败即返回 |
| `board_sh.py` | Linux 侧登录 + 批执行命令（参数用 `@@@` 分隔，行尾 `echo \_\_DONE\_\_` 做完成标记） |
| `uboot_loadx.py` / `xmodem_send.py` | 串口 XMODEM 传文件（**本板 U-Boot 无 loadx，未用上**） |
| `catch_shell_raw.bin` / `catch_shell_log.txt` | 复位抓包原始字节 + 监控日志 |
| `boot_after_fix_raw.bin` | ★修复后首次成功启动的完整日志 |

### RK 侧备份与恢复
| 路径 | 说明 |
|---|---|
| `D:\pango_work\dtb_orig.bin`（112,563B，crc32 `74a6f13e`） | ★原版内核 DTB（= FIT 期望 sha256 `c589cc9b`；已写回板子） |
| `D:\pango_work\dtb_new.bin`（112,579B） | 补丁版 DTB（pipe-grf=<291>，未使用） |
| `D:\pango_work\tftp\single_port_tftp.py` + `dtb_orig.bin` + `test1k.bin` | 单端口 TFTP 服务器 + 分发文件 |
| `D:\pango_work\bootlog.txt` | 上一轮的启动日志 |
| `F:\...\0-镜像\update.img` | 出厂全刷镜像（最后手段；**F 盘当前断开**） |

### 资料
- UP4 原理图：`F:\BaiduNetdiskDownload\RK3568-飞凌\硬件资料\2-PDF原理图\OK-3568-UP4 V1.3-A.pdf`（P29 信号名 `PCIE_A_*`）
- 官方 x4 参考工程（参数标准答案）：F 盘 `PCIE资料\pcie_test_platform_v1_0(1).zip` 内 `pcie_test_rtl\PG2L100H_PCIe_performance`
- 烧写命令文档：PDS doc 下 `UG990401_Fabric_Configuration_User_Guide.pdf` p80-107

---

## 七、踩坑速查表

| # | 坑 | 对策 |
|---|---|---|
| 1 | `NUM_OF_LANES` 是 bool | 永远保持 `5'b1`，lane 数改 WIDTH/CAPABLE/HSST_LANE_NUM |
| 2 | PDS synthesize 读 compile DB 缓存 | 改源码必须 `compile -force_to_run` + 删 prj_tasks |
| 3 | IP 条目 INVALID 不展开 | IP 的 .v 以 FILE 登记（systemverilog）+ 删 type="IP" 条目 |
| 4 | python re.sub raw replacement 写入 `\'` | 改 .v 用 Edit 工具/纯数字替换 |
| 5 | fdc 分支与 RTL 层次必须一致 | x2 下注释掉 gen2x4 的 define_attribute |
| 6 | `pnr -planning_before_place true` 报 Flow-0119 | 2025.2 合法值 Enable/Disable/Auto |
| 7 | **U-Boot 数字参数全是十六进制** | 写地址前自己换算成十六进制并复查 |
| 8 | tftpy 失败 | U-Boot 只认 69 端口源 → 用 single_port_tftp.py |
| 9 | U-Boot 手动启动别用 bootrkp | `boot_fit`（bootrkp 会报找不到 kernel 分区） |
| 10 | XR21 驱动句柄卡死 PermissionError 13 | 拔插 USB；MobaXterm 先杀进程 |
| 11 | RK 上电只探测一次 PCIe | 先烧好 FPGA 再让 RK 启动（JTAG+reboot 或固化） |
| 12 | 百度网盘静默写 MB 对齐全零块 | 新下载必跑 `tools\check_archives.py`（源码分卷包已中招） |
| 13 | 单机版 license 一次一个会话 | 占用者是 vish.exe/vlm.exe |
| 14 | busybox lspci 乱码 | 认 sysfs：vendor/device 0x0755（Pango 默认 ID） |
| 15 | **U-Boot 里 0x09000000 是 TrustZone/OP-TEE 保护区** | CPU 访问即 Data Abort → panic（TFTP 用它当加载地址同样炸）；**U-Boot 缓冲区一律 0x08300000** |
| 16 | 无驱动时读 PCI BAR 全 `0xFFFFFFFF` | COMMAND 的 Memory Space Enable=0 → `echo 1 > /sys/bus/pci/devices/0002:21:00.0/enable` |
| 17 | 板上 `dd`/批量读 `/dev/mem` 报 `Bad address` | 该内核只容忍单字访问；用 `devmem <addr> 32` 逐字读写 |
| 18 | boot 分区 DTB 坏了**不用**从 PC 传文件 | recovery 分区 +0x800 有原版副本，`mmc read`/`write` 本地修复（§2.6） |
| 19 | U-Boot `panic()` 后串口完全无响应 | 只能物理复位；提前挂 `catch_uboot_shell.py` 可自动接管进 shell |
| 20 | 串口长命令输出被截断/命令被切碎 | PC 侧批执行脚本的"完成标记"要匹配行首（`\n__DONE__`），别用会被回显命中的裸标记；命令内别用与分隔符相同的字符 |

---

## 八、环境速记

- 串口：COM14（XR21 Ch A 控制台，115200）；盘古 JTAG 调试器 = **FT2232H（本次 COM15/COM16）**
- RK Buildroot root 密码 = `root`
- U-Boot 静态 IP：板 169.254.33.200 ↔ PC 169.254.33.151（APIPA，网线直连；PC 网卡"以太网 5"）
- PDS 2025.2-ads（装于 `D:\pango_pds`，工具在 `bin\`）+ license 到 2029-09-09（host `00E04CF107DF`）；Questa 2025.3 license 到 2027-10-02
- EP 枚举（P29）：`0002:21:00.0` vendor=device=**0x0755**，**Gen2 x2**；BAR0=0xf0200000(8K)、BAR1=**0xf0204000(4K, DMA 寄存器)**、BAR2=0xf0202000(8K)
- devmem 访问 BAR 前必须 `echo 1 > .../enable`；DMA 测试缓冲区用 **0x110000**（ramoops 保留区）
- FPGA 板：**别断电**（配置是 SRAM 的）

---

*记忆索引同步条目：nesai-2026-pcie-enum-rk3568（x2+枚举+本次修正）、nesai-2026-rk3568-fit-dtb-repair（启动修复）、nesai-2026-uboot-devmem-gotchas（U-Boot/devmem 地址坑）、nesai-2026-up4-debug-serial-diagnosis（串口）、nesai-2026-pds-license-ads-setup（license）。*
