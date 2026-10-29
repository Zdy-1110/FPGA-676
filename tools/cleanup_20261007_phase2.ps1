# 2026-10-07 第二批清理：扩展板（PCIe 电源隔离转接板）PCB 工作线终止
# 依据用户指示："EDA/PCB 自动化区若仅是扩展板的 PCB 设计，则彻底清理"
# 范围：design\、delivery\、archive\ 三目录全删；review\ 仅删板卡专属部分。
# review\ 保留（与打板无关的工作线①③证据）：pcie_code_audit（厂商例程代码审计）、
#   hardware_connected（实板实测记录）、pango100pro_evidence.md（pcie_demo 恢复源 SHA-256 登记）、
#   cable_options.md（x4 延长线方案A选型）、rk_up4_* 与 p29/p30（RK3568 UP4 手册解析/原理图截图）。
# 全部送回收站，可恢复。根文档 00_最新PCIe评审_*.md 与 PCIe中间件_CEM触点映射_已核实.md 属板卡工作线但
# 在本次授权范围外，暂保留（README 已标注）。
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName Microsoft.VisualBasic
$base = 'E:\Project\nesai2026'

$files = @(
  'review\PCIE_REV_B_four_ground_domains.epro',
  'review\PCIE_REV_B_recovery_before_reload.epro',
  'review\PCIE_V4_NC_SCHEMA_REFERENCE.epro',
  'review\PCIE_V6_NATIVE_SCHEMA_REFERENCE.epro',
  'review\PCIe_INTERPOSER_REV_A_before_review.epro',
  'review\crop.py',
  'review\fetch_eda_api.py',
  'review\fetch_eda_methods.py',
  'review\inspect_native.py',
  'review\mark_v4_nc.js',
  'review\place_correct_parts.js',
  'review\verify_old_geometry.py',
  'review\verify_rev_b.py',
  'review\mechanical_audit.md',
  'review\rev_b_independent_review.md',
  'review\native_schematic_diagnostics.md'
)

$globs = @('api_*.html', 'api_*.txt', 'baseline_*', 'eda_*')  # review 根目录，嘉立创API文档快照 + Rev A基线 + Rev B会话日志

$dirs = @(
  'design',                                     # REV_C 设计工作区（生成/验证脚本、EDA会话证据、制造文件）
  'delivery',                                   # REV_C 发布包（文件夹+zip，从未制造）
  'archive',                                    # 10个旧云端EDA工程的本地备份（均为PCB旧版本）
  'review\baseline_export',                     # Rev A 基线导出
  'review\native_v4_before_symbol_split',       # REV_B V4 修复前快照
  'review\native_v5_before_nc_parent_fix',      # REV_B V5 修复前快照
  'review\final_isolator_rev_c_20261003',       # REV_C 独立验证产物（delivery 的上游）
  'review\two_manuals_20261003',                # 盘古手册页面证据（原件在资料包/fpga_docs）
  'review\bom_sourcing_20261003',               # 立创商城选型搜索证据
  'review\cleanup_bom_20261003',                # 云端工程清理会话证据（含11个epro的下载bundle）
  'review\pcie_two_variants_20261003'           # A/B 双方案评审
)

function Recycle-File($p) {
  if (Test-Path -LiteralPath $p) {
    try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin); Write-Output "OK   F  $p" }
    catch { Write-Output "ERR  F  $p :: $($_.Exception.Message)" }
  } else { Write-Output "MISS F  $p" }
}
function Recycle-Dir($p) {
  if (Test-Path -LiteralPath $p) {
    try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin); Write-Output "OK   D  $p" }
    catch { Write-Output "ERR  D  $p :: $($_.Exception.Message)" }
  } else { Write-Output "MISS D  $p" }
}

foreach ($f in $files) { Recycle-File (Join-Path $base $f) }
$rev = Join-Path $base 'review'
foreach ($g in $globs) {
  Get-ChildItem -LiteralPath $rev -Filter $g -File | ForEach-Object { Recycle-File $_.FullName }
}
foreach ($d in $dirs) { Recycle-Dir (Join-Path $base $d) }
Write-Output "==== phase2 done ===="
