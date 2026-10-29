# FPGA flash 固化 osd1c 方案（2026-10-18，待用户确认后执行）

## 1. 目的

osd1c 目前只通过 JTAG 加载，FPGA 一断电就丢失。flash 里存的是旧比特流，冷启动后在 P30 上建链失败（LTSSM 0x3，`lspci` 为空）。每次上电都得跑一遍 `fpga_reload.sh`，而 10-18 晚上这个脚本已经出过一次 RK 重启后挂死。

把 osd1c 写进 flash 后，两块板一起上电就能直接建链。

## 2. 硬件事实（来源：`fpga_docs/100pro_txt.txt` 第 738–790 行）

**FPGA 卡**
- 型号：MES2L676-100HP（盘古 100Pro），FPGA 为 PG2L100H-6IFBG676。

**flash**
- 两片 QSPI NOR，型号 W25Q128JV（手册注明兼容芯天下 XT25BF128FSSIGU-W），每片 128 Mbit，即 16 MB。
- U15 片选接 SPI0_CS（管脚 P18），是启动用的主 flash。U9 只在 x8 模式下使用，本方案不碰它。

**Pango 工具支持**
- 支持列表 `flash_list_cd.cfl` 里有 W25Q128Q（JEDEC ID 0xEF4018，16 MB，24 位地址），W25Q128JV 的 ID 与它相同。
- 列表里没有芯天下（XTX）。如果卡上实际贴的是 XT25BF128（ID 0x0B4018），扫描会识别失败，这时停下来汇报，不写 flash。

**操作方式**
- 用 PDS 的 "Jtag 间接烧写外部 flash"（`cfg_jtag_flash_*`），经 JTAG 由 FPGA 配置控制器转成 SPI。
- 操作期间 FPGA 用户逻辑会停掉，PCIe 链路随之断开，所以执行前必须先安全断链。10-15 实测过：链路在线时动 FPGA，RK 会挂死。

## 3. 需要生成的文件（已生成，未写入）

| 文件 | 说明 |
|---|---|
| `D:/pango_work/pango_pcie_dma_x2_osd1c.sfc` | 用 `cfg_gen_sfc -sbit …osd1c.sbit` 生成。读命令为默认的 0x0B（单线 Fast Read，24 位地址），起始地址 0x0。大小 3,791,112 字节，md5 24fc1ec8…，**与 osd1c.sbit 逐字节相同**。厂家 demo 的 `pcie_demo/4_15_PCIE_DMA/pnr/generate_bitstream/pango_pcie_dma_top.sfc` 也与它的 sbit 相同 |

- osd1c 编译时设置了 `master_configuration_clock_frequency 25M`。按单线读取估算，上电后约 1.2 秒加载完成。
- RK 内核大约在启动后 4.6 秒探测 PCIe，再加上 bootloader 的时间，余量充足。上次冷启动时 4.6 秒已能看到 LTSSM 0x3，说明那时 FPGA 已经配置完毕。
- 比特流选项保持默认：不压缩、开 CRC、SCBV=None（与厂家 demo 一致）。

**Tcl 脚本**（`tools/flash/`，已写好，未执行）

| 脚本 | 作用 |
|---|---|
| `flash_scan_backup.tcl` | 只读：识别 flash，回读两次，存为 `_a`、`_b` |
| `flash_program_osd1c.tcl` | 擦除 → 写入 osd1c.sfc → 校验 |
| `flash_restore_orig.tcl` | 回退：把备份写回 → 校验 |

## 4. 执行步骤（第 1–6 步由 Claude 执行，第 7 步需要用户断电）

1. **安全断链。** 在 RK 上移除 EP 0000:01:00.0，并对根端口 0000:00:00.0 置 LnkCtl.Link Disable，与 `fpga_reload.sh` 第 1 步相同。
2. **识别与备份（只读）。** 运行 `flash_scan_backup.tcl`。
   - 扫描结果必须是 W25Q128 系列（0xEF4018），否则停止。
   - 回读两次，两份 md5 必须一致。
3. **检查备份。**
   - 文件不小于 3.79 MB；
   - 文件头带 "PANGO MICROSYSTEMS" 和 Logos2-PG2L100H 字样；
   - 从文件头记下设计名和日期，并与盘上已知的 sbit 比对，以确认旧内容是什么。
   - 备份存两份：`D:/pango_work/flash_backup/` 和 `E:/Project/nesai2026/log/flash_backup/`。
   - **备份不合格就不进入第 4 步。**
4. **写 flash。** 运行 `flash_program_osd1c.tcl`，日志里必须看到 erase、program、verify 都成功。
5. **立即恢复工作状态。** 运行 `SLOT=p30 sh tools/fpga_reload.sh D:/pango_work/prog_x2_osd1c.tcl`，用 JTAG 加载 osd1c，然后重启 RK 并建链。
   - 这一步与 flash 内容无关，保证开发不中断。
   - 重启时同时录 COM9 串口，以防 RK 再次挂死。
6. 核对寄存器：魔数 OSD1，KEY_EVT 0，DRV 1。
7. **冷启动验收（需要用户）。** 两块板一起断电，再一起上电。之后由我检查：
   - 不经 JTAG，dmesg 中 3c0000000 显示 Link up；
   - 使能 EP 后魔数为 OSD1；
   - 显示器出图。

## 5. 回退办法

**整体前提：** JTAG 配置不依赖 flash。flash 只在上电时被读取一次（主 SPI 模式），即使内容坏了，FPGA 也只是上电后不配置，JTAG 照样能加载。所以这个操作不会把板子变砖。

| 情况 | 处理 |
|---|---|
| 第 2/3 步识别失败或备份异常 | 不写 flash，汇报。flash 里仍是原内容，状态与现在完全相同 |
| 第 4 步擦除、写入或校验失败 | flash 内容可能已经不完整。先用第 5 步的 JTAG 恢复工作状态，再按以下顺序处理：<br>① 重跑 `flash_program_osd1c.tcl`；<br>② 改用 `flash_restore_orig.tcl` 写回备份；<br>③ 备份也写不进去时，写厂家 demo 的 `pango_pcie_dma_top.sfc` 作为已知可启动的镜像 |
| 第 7 步冷启动仍不建链 | 照旧用 `fpga_reload.sh` 开发，不受影响。然后排查是加载时间还是 PERST 时序的问题。如需恢复旧内容，按上面的顺序断链后运行 `flash_restore_orig.tcl` |
| 想换回原出厂内容 | 安全断链，运行 `flash_restore_orig.tcl`，再 JTAG 重载并重启 RK |

## 6. 风险

- **断链。** 如果第 1 步没做或没生效，JTAG 访问 flash 时 RK 可能挂死，需要用户断电恢复。对策：第 1 步打印根端口 LnkCtl 确认 Link Disable 已生效。
- **擦除范围。** 擦除模式默认为 Auto（按文件大小），只擦 0x0–约 0x3A0000（约 58 个 64 KB 块），后面的内容保留。回读备份是否覆盖整片，以实际回读文件的大小为准。
- **耗时。** JTAG 间接读写 16 MB 级别的数据，速度未实测。估计回读每次几分钟，写入加校验几分钟。脚本按长超时运行。
- **以后的版本。** 每出一个新的稳定版本，都要重新生成 sfc 并重复第 1、4、5 步。开发期间仍用 JTAG 加载，只在版本稳定后才固化。

## 7. 执行记录（2026-10-18 23:05 起）

1. **安全断链：成功。** LnkCtl 由 0x0042 改为 0x0050，LnkSta 0xd011（DL_Active=0），EP 已移除。
2. **扫描 flash：失败，按第 5 节规定停止。** 没有回读，也没有写 flash，flash 仍是原内容。日志 `log/flash_plan/scan_out.txt`：
   - `cfg_scan_chain` 正常：PG2L100H，done bit 1。
   - `cfg_jtag_flash_scan_device` 报错，原文为 "The Flash ID detected is 0xb4018 … this flash type is not supported"。
   - 0x0B4018 = 芯天下（XTX）XT25BF128，**卡上贴的不是 W25Q128JV**。这个 ID 格式完整，不是时钟过快读出的乱码。
3. **恢复工作状态：成功。** 运行 `fpga_reload.sh`：JTAG 加载 osd1c，RK 重启后建链 5.0 GT/s x1，EP 已使能。寄存器：魔数 OSD1，KEY_EVT 0，DRV 1，OSD_CTRL 0x60，下溢 0，DISP_FRAMES 在递增。
4. **下一步需要用户决定：** 让 PDS 认识 XT25BF128。
   - 途径 1：在 `D:/pango_pds/arch/vendor/pango/arch/cdt/flash_list_cd.cfl` 里新增 XTX/XT25 厂商条目：型号 XT25BF128F，ID 0x000B4018，容量 0x8000000 bit，时间参数照抄 W25Q128Q，SPI X1/X2/X4，24 位地址。改之前先备份原文件，回退时拷回即可。
   - 途径 2：用户在 Fabric Configuration 的 GUI 里添加：Operations → Flash Operator → Add Flash。
   - 加好之后，从第 1 步重新执行本方案。
5. **用户同意改 flash 列表，改了两次（23:20–23:35）**
   - **目录权限。** PDS 安装目录只有管理员能写（Users 组只有 RX），所以由 `log/flash_plan/install_xtx_flash.ps1` 经 UAC 提权执行。
     - 脚本先把原文件备份为 `flash_list_cd.cfl.bak_20261018`，并确认备份的 md5 等于原版 18e0c9cd…，然后才覆盖。
     - 回退：用 UAC 运行 `rollback_xtx_flash.ps1`。
     - 项目内另存原版：`log/flash_plan/flash_list_cd.cfl.orig`。
   - **踩坑 1：脚本编码。** Windows PowerShell 5.1 把无 BOM 的 UTF-8 脚本按 GBK 读，第一行中文注释吞掉了换行，第二行的赋值没有执行，变量为空。改成纯 ASCII 后解决。
   - **踩坑 2：厂商名。** 第一次新增了 "XTX" 厂商块，扫描仍然报 0xb4018 不支持。原因是 cdt_js.exe 里写死了厂商表（MICRON/GIGA/WINBOND/XMC/CYPRESS/ZBIT/MXIC/PUYA/ISSI/SSMEC/ESMT/ADESTO/FENTECH/TSINGTENG），未知厂商整块被忽略。
     - 改为把同一条记录放进 WINBOND/W25Q 系列末尾：`["XT25BF128F","0x000B4018","0x8000000",[W25Q128Q 时间参数],[SPI X1/X2/X4 24 位],false]`。
     - 安装后 md5 为 5a54a2dd…，与原版相比只多这一条，JSON 已校验。
   - **结果。** 断链后重新扫描，`cfg_jtag_flash_scan_device` 执行成功（日志 `log/flash_plan/scan3_out.txt`）。
6. **备份（23:19）**
   - `cfg_jtag_flash_readback` 必须先 assign 一个文件，回读长度等于该文件的大小，否则报 "Flash device has no bitstream file"。所以先 assign `readsize_16m.sfc`（osd1c.sbit 补 0xFF 到 16 MB，只用来定长度），再整片回读两次，每次 20.5 秒。
   - 两份 md5 相同，都是 d5929b7a…，**整片全是 0xFF，flash 原本就是空的**。
   - 这与冷启动现象吻合：P30 的 LTSSM 0x3 加 Link Fail，与空槽位时相同，说明 FPGA 上电后没有被配置。
   - 备份存两处：`D:/pango_work/flash_backup/flash_orig_20261018_{a,b}.sfc` 和 `log/flash_backup/flash_orig_20261018_a.sfc`。
   - 回退 = 把 flash 擦回全 FF（或写回这份备份）。
7. **写入（23:21）**
   - 运行 `flash_program_osd1c.tcl`：擦除 12.6 秒，写入 61.6 秒，都成功。
   - `cfg_jtag_flash_verify` 没能执行。它要在 `D:/pango_pds/bin`（管理员目录）里创建 FlashReadBack_*.sfc，因打不开文件而中断。
   - 改用整片回读自行校验（`flash_after_osd1c_20261018.sfc`）：**前 3,791,112 字节与 osd1c.sbit 逐字节相同（md5 24fc1ec8…），其余全 FF**。这也证明回读通路读到的是真实数据。
8. **恢复工作状态（23:25）**：运行 `fpga_reload.sh`，P30 Link up，5.0 GT/s x1，寄存器正常。
9. **冷启动验收（23:30）：通过。** 用户把两块板一起断电再上电，全程没用 JTAG：
   - 内核 4.72 秒时 `3c0000000.pcie: PCIe Link up`，EP 0000:01:00.0 已枚举；
   - 使能 EP 后：5.0 GT/s x1，BAR f4200000/f4204000，魔数 OSD1，KEY_EVT 0，DRV 1，OSD_CTRL 0x60，下溢 0；
   - DISP_FRAMES 0x728，约 30 秒的帧数，说明 FPGA 上电即从 flash 加载；
   - test_feeder 655/655 帧，30.0 fps，late 0，下溢 0。
   - 日志：`log/flash_plan/coldboot_dmesg.txt`、`log/rk_env/test_feeder_run5_coldboot_flash.txt`。
   - **结论：以后上电不再需要 `fpga_reload.sh`。** RK 启动后仍要手动使能 EP（`enable` + CMD 0x06），`/tmp` 里的程序也要重新上传。
