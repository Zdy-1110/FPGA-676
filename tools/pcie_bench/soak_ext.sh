#!/bin/sh
# soak_ext.sh <secs> — 交替跑 pcie_bench 扩展长度 MWr 测试（x 模式，含逐档校验）和常规测试（含 4KB 回环校验），统计失败次数与 AER/RAS DES
/tmp/aer.sh clear; /tmp/rasdes.sh clear; /tmp/rasdes.sh on
end=$(( $(date +%s) + $1 )); n=0; bad=0
while [ $(date +%s) -lt $end ]; do
  /tmp/pcie_bench 0xf0204000 200 x > /tmp/x.out 2>&1 || { bad=$((bad + 1)); cp /tmp/x.out /tmp/x_fail_$n.out; }
  /tmp/pcie_bench 0xf0204000 500 > /tmp/b.out 2>&1 || { bad=$((bad + 1)); cp /tmp/b.out /tmp/b_fail_$n.out; }
  n=$((n + 1))
done
echo "=== END rounds=$n bad=$bad link=$(cat /sys/bus/pci/devices/0002:21:00.0/current_link_speed)/x$(cat /sys/bus/pci/devices/0002:21:00.0/current_link_width)"
/tmp/aer.sh show; /tmp/rasdes.sh dump; grep -E 'S=262144' /tmp/x.out; grep -E 'verify|fit' /tmp/b.out
