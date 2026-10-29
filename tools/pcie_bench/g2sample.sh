#!/bin/sh
# g2sample.sh [secs] — RK 上执行：Gen1→Gen2 重训练一次，空闲 secs 秒（默认 15）统计 P29 lane1 误码与 L0→Recovery 次数，然后退回 Gen1
/tmp/setlink.sh 1 0 >/dev/null; sleep 2
/tmp/setlink.sh 2 0 | sed 's/^/train: /'
/tmp/gen2check.sh ${1:-15} 2>&1 | grep -E 'lane1|ltssm|dll'
/tmp/setlink.sh 1 0 | sed 's/^/park: /'
