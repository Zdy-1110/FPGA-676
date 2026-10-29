#!/bin/sh
# deemph_sweep.sh <gen2ctrl_val> <trials> — 每次 Gen1→写 GEN2_CTRL→Gen2 重训练，1 秒后统计 L0→Recovery 次数与 lane1 误码
R=0002:20:00.0; E=/sys/bus/pci/devices/0002:21:00.0
for i in $(seq 1 $2); do
  /tmp/setlink.sh 1 0 >/dev/null; /tmp/pcicfg.sh w $R 0x80c $1 >/dev/null; /tmp/setlink.sh 2 0 >/dev/null
  /tmp/rasdes.sh clear; sleep 1
  echo "$1 trial$i speed=$(cat $E/current_link_speed | cut -c1-3) recov=$(/tmp/rasdes.sh get 5 0 0) rx_recov_req=$(/tmp/rasdes.sh get 1 7 0) l1dec=$(/tmp/rasdes.sh get 0 2 1) l0dec=$(/tmp/rasdes.sh get 0 2 0) deskew=$(/tmp/rasdes.sh get 1 10 0) ep_lnksta2=$(od -An -tx2 -j162 -N2 $E/config)"
done
