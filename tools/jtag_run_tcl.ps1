# Run a Pango JTAG tcl script via cdt_js + cdt_cfg_shell, print output. Usage: jtag_run_tcl.ps1 <tcl-path>
param([Parameter(Mandatory=$true)][string]$Tcl)
$bin = 'D:\pango_pds\bin'; $work = 'D:\pango_work'
$started = $false
if (-not (Get-Process cdt_js -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath "$bin\cdt_js.exe" -ArgumentList '-port','65421' -WorkingDirectory $bin -WindowStyle Minimized
    $started = $true; Start-Sleep -Seconds 4
}
& "$bin\cdt_cfg_shell.exe" -work_dir $work -file $Tcl 2>&1 | ForEach-Object { $_ }
if ($started) { Get-Process cdt_js -ErrorAction SilentlyContinue | Stop-Process -Force }
