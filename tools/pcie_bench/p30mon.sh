#!/bin/sh
# p30mon.sh [secs] — 逐秒记录 P30 (pcie2x1, 根端口 0000:00:00.0) 的 LTSSM、LnkSta、RAS DES 计数；只读根端口配置空间
export RP=0000:00:00.0 VS=0x170
F=/sys/bus/pci/devices/$RP/config
/tmp/rasdes.sh on; /tmp/rasdes.sh clear
for i in $(seq 1 ${1:-60}); do
  d0=$(od -An -tu4 -j1832 -N4 $F | tr -d ' ')
  printf '%s up=%s ltssm=0x%02x LnkSta=0x%s l0_recov=%s dec0=%s disp0=%s rx_err=%s replay_to=%s\n' "$(date +%T)" "$(cut -d' ' -f1 /proc/uptime)" $((d0 & 63)) \
    $(od -An -tx2 -j130 -N2 $F | tr -d ' ') $(/tmp/rasdes.sh get 5 0 0) $(/tmp/rasdes.sh get 0 2 0) $(/tmp/rasdes.sh get 0 3 0) $(/tmp/rasdes.sh get 1 6 0) $(/tmp/rasdes.sh get 2 4 0)
  sleep 1
done
