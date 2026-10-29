#!/bin/sh
# gen2check.sh [secs] — 不重训练链路：报告当前速率/宽度，清零 AER 与 RAS DES 计数，空闲等待 secs 秒(默认 60)后汇报每 lane 误码
D=/sys/bus/pci/devices/0002:21:00.0
echo "link=$(cat $D/current_link_speed)/x$(cat $D/current_link_width)"
/tmp/aer.sh clear; /tmp/rasdes.sh clear; /tmp/rasdes.sh on
sleep ${1:-60}
/tmp/rasdes.sh dump; /tmp/aer.sh show
echo "link=$(cat $D/current_link_speed)/x$(cat $D/current_link_width)"
