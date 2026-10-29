#!/bin/sh
# fpga_reload.sh <prog.tcl> — 安全换 FPGA 比特流并恢复 PCIe（流程取自 test_variant.sh，去掉了误码测试）：
#   1) RK 上先移除 EP 设备、再用根端口 LnkCtl.Link Disable 断链（链路在线时直接烧 FPGA 会让 RK 挂死，20261015 实测）
#   2) JTAG 烧写  3) 软重启 RK，建链失败再重启一次  4) 使能 EP（enable + COMMAND 低字节 0x06）
#   SLOT=p30 时改用 P30（pcie2x1，x1）；默认 P29（pcie3x2）
cd /e/Project/nesai2026; export MSYS_NO_PATHCONV=1
H=192.168.3.51
if [ "$SLOT" = p30 ]; then CTL=3c0000000; EPD=0000:01:00.0; RPD=0000:00:00.0; else CTL=3c0800000; EPD=0002:21:00.0; RPD=0002:20:00.0; fi
wait_ssh() { for i in $(seq 1 40); do py -3 -c "
import socket,sys; s=socket.socket(); s.settimeout(1.5)
try: s.connect(('$H',22)); sys.exit(0)
except Exception: sys.exit(1)" && return 0; sleep 3; done; return 1; }
reboot_rk() { timeout 30 py -3 tools/rk_ssh.py $H "sync; (sleep 1; reboot) >/dev/null 2>&1 &" >/dev/null; sleep 30; wait_ssh || { echo "RK not back"; exit 1; }; sleep 3; }
link_up() { timeout 30 py -3 tools/rk_ssh.py $H "dmesg | grep -E '$CTL.pcie: PCIe Link (up|Fail)'; dmesg | grep -E '$CTL.pcie: PCIe Linking' | tail -1" | tee /tmp/fr_link.txt; grep -q "Link up" /tmp/fr_link.txt; }
echo "===== link down safely"
timeout 30 py -3 tools/rk_ssh.py $H "E=/sys/bus/pci/devices/$EPD; [ -e \$E ] && echo 1 > \$E/remove; R=/sys/bus/pci/devices/$RPD; if [ -e \$R ]; then printf '\\120' | dd of=\$R/config bs=1 seek=128 count=1 conv=notrunc 2>/dev/null; sleep 1; od -An -tx2 -j128 -N4 \$R/config; fi; echo removed"
echo "===== program $1"
timeout 100 powershell -NoProfile -ExecutionPolicy Bypass -File tools/jtag_run_tcl.ps1 -Tcl "$1" 2>&1 | grep -iE 'done bit is|Program\]|error|fail' | tail -3
reboot_rk
if ! link_up; then echo "link failed, reboot once more"; reboot_rk; link_up || { echo "LINK FAIL twice"; exit 2; }; fi
echo "===== enable EP"
timeout 30 py -3 tools/rk_ssh.py $H "E=/sys/bus/pci/devices/$EPD; echo 1 > \$E/enable; printf '\\006' | dd of=\$E/config bs=1 seek=4 count=1 conv=notrunc 2>/dev/null; od -An -tx2 -j4 -N2 \$E/config; cat \$E/current_link_speed \$E/current_link_width; od -An -tx4 -j16 -N8 \$E/config"
