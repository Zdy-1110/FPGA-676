#!/bin/sh
# reboot_loop.sh <N> — PC 端执行：软重启 RK N 次（FPGA 保持配置），统计 P29 建链结果
# 可选环境变量：CTL=控制器地址(默认 3c0800000=P29) EP=端点 BDF(默认 0002:21:00.0) WANT=期望宽度(默认 x2)；P30 用 CTL=3c0000000 EP=0000:01:00.0 WANT=x1
# 每次记录：dmesg 的 Link up/Fail 行、速率/宽度、根端口与 EP 的 AER；RK 2 分钟内回不来就停止
cd /e/Project/nesai2026; export MSYS_NO_PATHCONV=1
H=192.168.3.51; ok=0; CTL=${CTL:-3c0800000}; EP=${EP:-0002:21:00.0}; WANT=${WANT:-x2}
wait_ssh() { for i in $(seq 1 40); do py -3 -c "
import socket,sys; s=socket.socket(); s.settimeout(1.5)
try: s.connect(('$H',22)); sys.exit(0)
except Exception: sys.exit(1)" && return 0; sleep 3; done; return 1; }
for n in $(seq 1 $1); do
  timeout 30 py -3 tools/rk_ssh.py $H "sync; (sleep 1; reboot) >/dev/null 2>&1 &" >/dev/null
  sleep 30; wait_ssh || { echo "#$n RK not back after reboot — STOP"; exit 1; }; sleep 3
  r=$(timeout 30 py -3 tools/rk_ssh.py $H "D=/sys/bus/pci/devices/$EP; dmesg | grep -E '$CTL.pcie: PCIe Link (up|Fail)' | tail -1; [ -e \$D ] && echo \"speed=\$(cat \$D/current_link_speed) width=x\$(cat \$D/current_link_width)\" || echo 'EP absent'; echo \"soc_temp=\$(cat /sys/class/thermal/thermal_zone0/temp)\"")
  echo "#$n $(date +%T) $(echo "$r" | grep -v '^#####' | grep -E 'Link|speed|EP absent|soc_temp' | tr '\n' ' ')"
  echo "$r" | grep -q "width=$WANT" && ok=$((ok + 1))
done
echo "RESULT: $ok/$1 reboots linked at $WANT"
