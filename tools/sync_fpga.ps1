# tools/sync_fpga.ps1
# 同步 FPGA 源码快照至 fpga/ 目录

[CmdletBinding()]
param(
    [string]$SourceDir = "D:\pango_build\4_15_PCIE_DMA",
    [string]$TargetDir = "",
    [string]$BitstreamDir = "D:\pango_work\quad\out"
)

$ErrorActionPreference = "Stop"

if (-not $TargetDir) {
    $TargetDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\fpga"))
} else {
    $TargetDir = [System.IO.Path]::GetFullPath($TargetDir)
}

$SourceDir = [System.IO.Path]::GetFullPath($SourceDir)
if ($BitstreamDir -and (Test-Path $BitstreamDir)) {
    $BitstreamDir = [System.IO.Path]::GetFullPath($BitstreamDir)
}

if (-not (Test-Path $SourceDir)) {
    throw "Source directory does not exist: $SourceDir"
}

if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
}

function Invoke-RoboCopySafe {
    param(
        [Parameter(Mandatory=$true)][string]$Src,
        [Parameter(Mandatory=$true)][string]$Dst,
        [string[]]$Files = @(),
        [string[]]$Options = @()
    )

    if (-not (Test-Path $Src)) {
        Write-Warning "Source path does not exist: $Src"
        return
    }

    if (-not (Test-Path $Dst)) {
        New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    }

    $cmdArgs = @($Src, $Dst)
    if ($Files -and $Files.Count -gt 0) {
        $cmdArgs += $Files
    }
    if ($Options -and $Options.Count -gt 0) {
        $cmdArgs += $Options
    }

    & robocopy.exe @cmdArgs | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        throw "Robocopy failed ($Src -> $Dst) with exit code $rc"
    }
}

# 1. 根目录 *.pds / *.tcl / readme.txt
Invoke-RoboCopySafe -Src $SourceDir -Dst $TargetDir -Files @("*.pds", "*.tcl", "readme.txt") -Options @(
    "/XF", "*.log",
    "/MAX:20971520",
    "/R:1", "/W:1", "/NP"
)

# 2. 源码主目录：src, ip, bench, linux, docs, ref_ddr, ref_hdmi
$mainDirs = @("src", "ip", "bench", "linux", "docs", "ref_ddr", "ref_hdmi")
foreach ($d in $mainDirs) {
    $s = Join-Path $SourceDir $d
    $t = Join-Path $TargetDir $d
    if (Test-Path $s) {
        Invoke-RoboCopySafe -Src $s -Dst $t -Options @(
            "/E", "/MIR",
            "/XD", "backup_*", "logbackup", "out", "prj_tasks", "simulation", "work", "work_*",
            "/XF", "*.log",
            "/MAX:20971520",
            "/R:1", "/W:1", "/NP"
        )
    }
}

# 3. pnr 约束与工程配置：只包含 *.tcl, *.pds, *.fdc
$sPnr = Join-Path $SourceDir "pnr"
$tPnr = Join-Path $TargetDir "pnr"
if (Test-Path $sPnr) {
    Invoke-RoboCopySafe -Src $sPnr -Dst $tPnr -Files @("*.tcl", "*.pds", "*.fdc") -Options @(
        "/MIR",
        "/XD", "logbackup", "prj_tasks",
        "/XF", "*.log",
        "/MAX:20971520",
        "/R:1", "/W:1", "/NP"
    )
}

# 4. sim 子目录源码：sim/lane, sim/lane2, sim/lane_board, sim/osd_lane, sim/lane_gl
$simSubs = @("lane", "lane2", "lane_board", "osd_lane", "lane_gl")
foreach ($sub in $simSubs) {
    $s = Join-Path $SourceDir "sim\$sub"
    $t = Join-Path $TargetDir "sim\$sub"
    if (Test-Path $s) {
        Invoke-RoboCopySafe -Src $s -Dst $t -Files @("*.v", "*.sv", "*.vh", "*.h", "*.sh", "*.tcl", "*.ps1", "*.md") -Options @(
            "/S", "/MIR",
            "/XD", "work", "work_*", "prj_tasks", "@_*", "_*",
            "/XF", "*.log", "*.wlf", "transcript", "*.qdb", "*.qpg", "*.qtl", "*.vm",
            "/MAX:20971520",
            "/R:1", "/W:1", "/NP"
        )
    }
}

# 5. sim_* 独立仿真目录源码：sim_ddr, sim_disp, sim_mrd, sim_ms72
$simDirs = @("sim_ddr", "sim_disp", "sim_mrd", "sim_ms72")
foreach ($sd in $simDirs) {
    $s = Join-Path $SourceDir $sd
    $t = Join-Path $TargetDir $sd
    if (Test-Path $s) {
        Invoke-RoboCopySafe -Src $s -Dst $t -Files @("*.v", "*.sv", "*.vh", "*.h", "*.sh", "*.tcl", "*.ps1", "*.md") -Options @(
            "/S", "/MIR",
            "/XD", "work", "work_*", "prj_tasks", "@_*", "_*", "data", "lint",
            "/XF", "*.log", "*.wlf", "transcript", "*.qdb", "*.qpg", "*.qtl", "*.raw", "*.nv12", "*.hex",
            "/MAX:20971520",
            "/R:1", "/W:1", "/NP"
        )
    }
}

# 6. 位流文件：新建 fpga/out/，只放 quad_cam9.sbit 与 quad_cam10f.sbit
$tOut = Join-Path $TargetDir "out"
if (-not (Test-Path $tOut)) {
    New-Item -ItemType Directory -Force -Path $tOut | Out-Null
}
if ($BitstreamDir -and (Test-Path $BitstreamDir)) {
    $bitstreams = @("quad_cam9.sbit", "quad_cam10f.sbit")
    foreach ($bs in $bitstreams) {
        $bsSrc = Join-Path $BitstreamDir $bs
        if (Test-Path $bsSrc) {
            Copy-Item -Path $bsSrc -Destination (Join-Path $tOut $bs) -Force
        }
    }
    # 严格确保只有指定的 2 个 sbit
    Get-ChildItem -Path $tOut -File | Where-Object { $_.Name -notin $bitstreams } | Remove-Item -Force
}

# 7. 统计同步后的文件数与总字节
$allFiles = Get-ChildItem -Path $TargetDir -Recurse -File
$totalCount = $allFiles.Count
$totalBytes = ($allFiles | Measure-Object -Sum Length).Sum

Write-Host "--------------------------------------------------"
Write-Host "FPGA snapshot sync complete."
Write-Host "Target directory: $TargetDir"
Write-Host "Total files     : $totalCount"
Write-Host "Total bytes     : $totalBytes bytes ($([math]::Round($totalBytes / 1MB, 2)) MB)"
Write-Host "--------------------------------------------------"
