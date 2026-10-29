<#
.SYNOPSIS
    Run tools/npu_det/compare_board_sim.py inside the WSL conda environment 'rknn15'.

.DESCRIPTION
    Thin Windows-side wrapper: converts this repository's Windows path to the WSL
    path (/mnt/<drive>/...), activates the RKNN-Toolkit2 1.5 environment and runs
    the comparison script from the repository root. Every argument is forwarded
    unchanged, so the Python script's own --help applies.

.EXAMPLE
    .\tools\npu_det\run_compare_sim.ps1 --model b2f `
        --board-csv log/npu_det/20261026_132715_npu_det.csv `
        --video video_review/src/video_20260929_113343.mp4 --stride 10

.EXAMPLE
    .\tools\npu_det\run_compare_sim.ps1 --model b2f --rgb models/npu/bench_input_960x320.rgb `
        --frame 0 --board-csv log/npu_det/20261026_132715_npu_det.csv `
        --video video_review/src/video_20260929_113343.mp4

.NOTES
    Optional switches (single dash, consumed by the wrapper):
        -CondaEnv   conda environment name   (default: rknn15)
        -CondaRoot  conda installation root  (default: /home/zdy/miniconda3)
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$CondaEnv = "rknn15",
    [string]$CondaRoot = "/home/zdy/miniconda3",
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..")).Path

if (-not ($repoRoot -match '^([A-Za-z]):(.*)$')) {
    throw "Cannot map '$repoRoot' to a WSL path (expected a drive-letter path such as E:\Project\...)"
}
$drive = $Matches[1].ToLower()
$tail = $Matches[2].Replace('\', '/')
$wslRoot = "/mnt/$drive$tail"

function ConvertTo-BashArg([string]$value) {
    if ($null -eq $value) { return "''" }
    return "'" + $value.Replace("'", "'\''") + "'"
}

$argLine = ""
if ($Rest) {
    foreach ($a in $Rest) { $argLine += " " + (ConvertTo-BashArg $a) }
}

$scriptRel = "tools/npu_det/compare_board_sim.py"
$cmd = "source " + (ConvertTo-BashArg ($CondaRoot + "/etc/profile.d/conda.sh")) + " && " +
       "conda activate " + (ConvertTo-BashArg $CondaEnv) + " && " +
       "cd " + (ConvertTo-BashArg $wslRoot) + " && " +
       "python " + $scriptRel + $argLine

Write-Host "[run_compare_sim] repo  : $repoRoot -> $wslRoot"
Write-Host "[run_compare_sim] env   : $CondaEnv"
Write-Host "[run_compare_sim] cmd   : python $scriptRel$argLine"

& wsl.exe -e bash -lc $cmd
$code = $LASTEXITCODE
Write-Host "[run_compare_sim] exit  : $code"
exit $code
