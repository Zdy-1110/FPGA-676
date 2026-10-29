# Read-only JTAG check: start the Pango JTAG server, run check.tcl (connect + scan chain only), print the result.
# Never calls cfg_program / cfg_assign_file.
$ErrorActionPreference = 'Continue'
$bin = 'D:\pango_pds\bin'
$work = 'D:\pango_work'

$started = $false
if (-not (Get-Process cdt_js -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath "$bin\cdt_js.exe" -ArgumentList '-port', '65421' -WorkingDirectory $bin -WindowStyle Minimized
    $started = $true
    Start-Sleep -Seconds 4
}

$out = & "$bin\cdt_cfg_shell.exe" -work_dir $work -file "$work\check.tcl" 2>&1
$out | ForEach-Object { $_ }

Write-Output '--- configuration_tcl.log (tail) ---'
Get-Content "$work\configuration_tcl.log" -Tail 6

if ($started) {
    Get-Process cdt_js -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Output 'cdt_js stopped (was started by this script)'
}
