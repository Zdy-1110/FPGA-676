# 2026-10-07 工作区清理脚本（全部送回收站，可恢复）
# 依据：三路只读盘点结论，见根目录 README.md「2026-10-07 清理记录」一节
# 删除分三类：①零信息量残留 ②已验证的逐字节重复体 ③可再生产物（恢复路径见 README）
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName Microsoft.VisualBasic
$base = 'E:\Project\nesai2026'
$P13  = 'pcie_demo\2_13_pcie_test\2_13_pcie_test\pcie_test'

$files = @(
  # ---- 根目录：意外残留 / 无关文件 / 重复提取 ----
  '({text',                          # 0字节，CDP脚本重定向意外产物
  'debug.log',                       # Chromium/ANGLE临时日志，无项目信息
  'mailto_UserChoice_backup.reg',    # 系统邮件关联注册表备份，与本项目无关
  'contest_doc.txt',                 # 劣化提取(仅3071字符)，保留contest_pymupdf.txt
  'contest_utf8.txt',                # 与pymupdf版相似度0.9975的重复
  '_extract_anlogic.py',             # 一次性提取脚本，来源PDF在D:\QQ\文件
  'tools\api.py',                    # HTTP报错文本残留(非代码)
  'tools\filelist.json',             # KiCad库下载404响应残留
  'tools\filelist2.json',            # KiCad库下载502响应残留
  'tools\boot_chA.log',              # 23字节抓取标记，现场记录保留在boot_console.log
  'tools\boot_chB.log',              # 0字节
  'tools\boot_chC.log',              # 0字节
  'tools\boot_chD.log',              # 0字节
  'tools\verify_full_render.png',    # 一次性几何核对图
  'tools\verify_p2_fix.png',         # 一次性几何核对图
  'tools\up4_bottom_right.png',      # UP4资料页截图，可从F盘飞凌资料重渲染
  'tools\up4_half_left.png',
  'tools\up4_half_right.png',
  'tools\up4_left_slots.png',
  'tools\up4_page1_board.png',
  'tools\up4_page1_full.png',
  'tools\up4_top_center.png',
  'tools\up4_top_left.png',
  'tools\xr_usb_driver_win10.zip',   # 与tools\xr_usb_driver\目录内容一致，保留目录
  # ---- design：已验证逐字节可再生/重复的派生物 ----
  'design\PCIE_POWER_ISOLATOR_X4_REV_C\manufacturing\BOM_EDA_NATIVE_UTF8.tsv',  # 由同名.csv转码
  'design\PCIE_POWER_ISOLATOR_X4_REV_C\manufacturing\CPL_EDA_NATIVE_UTF8.tsv',  # 由同名.csv转码
  'design\PCIE_POWER_ISOLATOR_X4_REV_C\eda_bom_cpl_netlist_response.json',      # 解码结果=BOM/CPL/NETLIST三份保留件
  # ---- pcie_demo 2_13：厂商构建日志 ----
  "$P13\pds.log",
  "$P13\ipcore\pcie_test\generate.log",
  "$P13\ipcore\pcie_test\.last_generated",
  "$P13\ipcore\pcie_test\pnr\example_design\pds.log",
  "$P13\ipcore\pcie_test\pnr\example_design\run.log",
  "$P13\ipcore\pcie_test\pnr\example_design\generate_bitstream\bgr.db",
  "$P13\ipcore\pcie_test\pnr\example_design\generate_bitstream\run.log",
  # ---- pcie_demo 4_15：厂商构建日志/锁/预编译x86二进制(x86-64，RK3568用不了) ----
  'pcie_demo\4_15_PCIE_DMA\pnr\pds.log',
  'pcie_demo\4_15_PCIE_DMA\pnr\run.log',
  'pcie_demo\4_15_PCIE_DMA\pnr\stderr.log',
  'pcie_demo\4_15_PCIE_DMA\pnr\stdout.log',
  'pcie_demo\4_15_PCIE_DMA\pnr\pg2l_pcie_dma.pds.lock',
  'pcie_demo\4_15_PCIE_DMA\ip\PCIe_IP\pnr\example_design\pds.log',
  'pcie_demo\4_15_PCIE_DMA\simulation\vsim.log',
  'pcie_demo\4_15_PCIE_DMA\linux\dma_pio_app',            # ELF x86-64 预编译
  'pcie_demo\4_15_PCIE_DMA\linux\pio_test',               # ELF x86-64 预编译
  'pcie_demo\4_15_PCIE_DMA\linux\pango_pci_driver.ko',    # vermagic 4.15 x86-64
  'pcie_demo\4_15_PCIE_DMA\linux\driver\.cache.mk',       # kbuild缓存
  'pcie_demo\4_15_PCIE_DMA\linux\driver\.pango_pci_driver.c.swp'  # vim交换文件
)

$dirs = @(
  '.video_agent',                                              # video-agent插件自动重建
  'tools\__pycache__',
  'tools\platform-tools',                                      # 保留platform-tools.zip(内容一致)
  'tools\gerber_preview_deps',                                 # gerbonara依赖树，无脚本引用，pip可重装
  'design\PCIE_POWER_ISOLATOR_X4_REV_C\__pycache__',
  'design\PCIE_POWER_ISOLATOR_X4_REV_C\eda_native',            # FINAL.epro逐字节解包副本，decode_eda_final_exports.py可重建
  'design\PCIE_POWER_ISOLATOR_X4_REV_C\manufacturing\gerber',  # 原始Gerber zip的解包，同上可重建
  'review\pcie_code_audit_20261003\extracted',                 # 164MB，与pcie_demo逐字节同体；源.rar在F盘(SHA-256已核对)
  "$P13\logbackup",
  "$P13\ipcore\pcie_test\pnr\example_design\compile",
  "$P13\ipcore\pcie_test\pnr\example_design\constraint_check",
  "$P13\ipcore\pcie_test\pnr\example_design\device_map",
  "$P13\ipcore\pcie_test\pnr\example_design\place_route",
  "$P13\ipcore\pcie_test\pnr\example_design\report_timing",
  "$P13\ipcore\pcie_test\pnr\example_design\synthesize",
  "$P13\ipcore\pcie_test\pnr\example_design\log",
  "$P13\ipcore\pcie_test\pnr\example_design\logbackup",
  "$P13\ipcore\pcie_test\pnr\example_design\generate_bitstream\bak",
  "$P13\ipcore\pcie_test\pnr\example_design\generate_bitstream\logbackup",
  'pcie_demo\4_15_PCIE_DMA\pnr\compile',
  'pcie_demo\4_15_PCIE_DMA\pnr\constraint_check',
  'pcie_demo\4_15_PCIE_DMA\pnr\device_map',
  'pcie_demo\4_15_PCIE_DMA\pnr\place_route',
  'pcie_demo\4_15_PCIE_DMA\pnr\report_timing',
  'pcie_demo\4_15_PCIE_DMA\pnr\synthesize',
  'pcie_demo\4_15_PCIE_DMA\pnr\log',
  'pcie_demo\4_15_PCIE_DMA\pnr\generate_bitstream\bak',
  'pcie_demo\4_15_PCIE_DMA\pnr\generate_bitstream\logbackup'
)

$ok = 0; $err = 0; $miss = 0
foreach ($f in $files) {
  $p = Join-Path $base $f
  if (Test-Path -LiteralPath $p) {
    try {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
      Write-Output "OK   F  $f"; $ok++
    } catch { Write-Output "ERR  F  $f :: $($_.Exception.Message)"; $err++ }
  } else { Write-Output "MISS F  $f"; $miss++ }
}
foreach ($d in $dirs) {
  $p = Join-Path $base $d
  if (Test-Path -LiteralPath $p) {
    try {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
      Write-Output "OK   D  $d"; $ok++
    } catch { Write-Output "ERR  D  $d :: $($_.Exception.Message)"; $err++ }
  } else { Write-Output "MISS D  $d"; $miss++ }
}
Write-Output "==== deleted=$ok error=$err missing=$miss ===="
