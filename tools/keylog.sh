#!/bin/sh
# keylog.sh [seconds] — 在 RK 上每 0.1 s 读 KEY_EVT/DRV_STATE/CAL_*，有变化就记一行（按键上板测试用）
# 列：时间 KEY_EVT(0x844) DRV_STATE(0x848) CAL_CTRL(0x980) CAL_VP(0x984) CAL_BAND(0x988) CAL_GUIDE(0x98C)
#   用法：start-stop-daemon -S -b -x /tmp/keylog.sh -- 1200 /tmp/keylog.txt（第 2 个参数为输出文件）
[ -n "$2" ] && exec > "$2" 2>&1
B=${BAR1:-f4204000}; F=/tmp/pcie_feed
end=$(( $(date +%s) + ${1:-300} )); prev=""
while [ "$(date +%s)" -lt "$end" ]; do
    s=""
    for o in 844 848 980 984 988 98c; do s="$s $($F $B get $o | cut -d= -f2)"; done
    if [ "$s" != "$prev" ]; then echo "$(date +%T)$s"; prev="$s"; fi
    usleep 100000 2>/dev/null || sleep 1
done
echo done
