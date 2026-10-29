#!/bin/sh
# soak.sh <secs> [iters] — 循环跑 pcie_bench（每轮含 4KB 回环校验 + 双向 DMA 长度扫描），
# AER 与 RAS DES 计数从开始累计，每 60 s 记录一次；失败轮次的输出另存 /tmp/b_fail_<n>.out
D=/sys/bus/pci/devices/${EPDEV:-0002:21:00.0}   # P30: EPDEV=0000:01:00.0 BAR=0xf4204000 RP=0000:00:00.0 VS=0x170
echo 1 > $D/enable 2>/dev/null
printf '\006\004' | dd of=$D/config bs=1 seek=4 count=2 conv=notrunc 2>/dev/null   # COMMAND=0x0406 (Mem+BusMaster)
/tmp/aer.sh clear; /tmp/rasdes.sh clear; /tmp/rasdes.sh on
end=$(( $(date +%s) + $1 )); next=$(( $(date +%s) + 60 )); runs=0; ok=0; bad=0
while [ $(date +%s) -lt $end ]; do
  /tmp/pcie_bench ${BAR:-0xf0204000} ${2:-2000} > /tmp/b.out 2>&1; rc=$?
  runs=$((runs + 1))
  if [ $rc -eq 0 ] && ! grep -q '!!' /tmp/b.out; then ok=$((ok + 1)); else bad=$((bad + 1)); cp /tmp/b.out /tmp/b_fail_$runs.out; fi
  if [ $(date +%s) -ge $next ]; then
    echo "=== $(date +%T) runs=$runs ok=$ok bad=$bad link=$(cat $D/current_link_speed)/x$(cat $D/current_link_width)"
    /tmp/aer.sh show; /tmp/rasdes.sh dump | grep -E 'lane|dll|ltssm|common'
    next=$((next + 60))
  fi
done
echo "=== END runs=$runs ok=$ok bad=$bad link=$(cat $D/current_link_speed)/x$(cat $D/current_link_width)"
/tmp/aer.sh show; /tmp/rasdes.sh dump
grep -E 'verify|fit' /tmp/b.out
