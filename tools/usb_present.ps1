[Console]::OutputEncoding = [Text.Encoding]::UTF8
Write-Output "== USB / serial / JTAG devices (present) =="
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^USB|^FTDIBUS|^FTDI' -or $_.Class -in 'Ports','USB','USBDevice' } |
    Select-Object Status, Class, FriendlyName, InstanceId | Format-Table -AutoSize -Wrap | Out-String -Width 250
Write-Output "== Ports class (incl. not present) =="
Get-PnpDevice -Class Ports | Select-Object Status, FriendlyName, InstanceId | Format-Table -AutoSize -Wrap | Out-String -Width 250
