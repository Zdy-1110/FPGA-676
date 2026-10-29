#!/bin/sh
# test_variant.sh <prog.tcl> <tag> — 安全换 FPGA 版本并测 Gen2 误码：
#   1) RK 上先移除 EP 设备、再用根端口 LnkCtl.Link Disable 主动断链（链路在线时直接烧 FPGA 会让 RK 挂死，20261015 实测）
#   2) JTAG 烧写 → 3) 软重启 RK，若建链失败再重启一次 → 4) 60 s 空闲误码 + 3 个 1 s 窗口
cd /e/Project/nesai2026; export MSYS_NO_PATHCONV=1
H=192.168.3.51
wait_ssh() { for i in $(seq 1 40); do py -3 -c "
import socket,sys; s=socket.socket(); s.settimeout(1.5)
try: s.connect(('$H',22)); sys.exit(0)
except Exception: sys.exit(1)" && return 0; sleep 3; done; return 1; }
reboot_rk() { timeout 30 py -3 tools/rk_ssh.py $H "sync; (sleep 1; reboot) >/dev/null 2>&1 &" >/dev/null; sleep 30; wait_ssh || { echo "RK not back"; exit 1; }; sleep 3; }
link_up() { timeout 30 py -3 tools/rk_ssh.py $H "dmesg | grep -E '3c0800000.pcie: PCIe Link (up|Fail)'; dmesg | grep -E '3c0800000.pcie: PCIe Linking' | tail -1" | tee /tmp/tv_link.txt; grep -q "Link up" /tmp/tv_link.txt; }
echo "===== $2: link down safely"
timeout 30 py -3 tools/rk_ssh.py $H "E=/sys/bus/pci/devices/0002:21:00.0; [ -e \$E ] && echo 1 > \$E/remove; R=/sys/bus/pci/devices/0002:20:00.0; if [ -e \$R ]; then printf '\\120' | dd of=\$R/config bs=1 seek=128 count=1 conv=notrunc 2>/dev/null; sleep 1; od -An -tx2 -j128 -N4 \$R/config; fi; echo removed"
echo "===== $2: program $1"
timeout 100 powershell -NoProfile -ExecutionPolicy Bypass -File tools/jtag_run_tcl.ps1 -Tcl "$1" 2>&1 | grep -iE 'done bit is|Program\]|error|fail' | tail -2
reboot_rk
if ! link_up; then echo "link failed, reboot once more"; reboot_rk; link_up || { echo "$2: LINK FAIL twice"; exit 2; }; fi
for f in aer.sh rasdes.sh pcicfg.sh lanestat.sh gen2check.sh setlink.sh pcie_bench; do py -3 tools/rk_put.py $H tools/pcie_bench/$f /tmp/$f 755 >/dev/null; done
timeout 30 py -3 tools/rk_ssh.py $H "nohup /tmp/gen2check.sh 60 > /tmp/g.log 2>&1 &" >/dev/null
sleep 63
timeout 30 py -3 tools/rk_ssh.py $H "cat /tmp/g.log" "for i in 1 2 3; do /tmp/rasdes.sh clear; sleep 1; /tmp/rasdes.sh dump | grep -E 'lane1|ltssm'; done"
