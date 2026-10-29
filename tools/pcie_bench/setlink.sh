#!/bin/sh
# setlink.sh <target 1|2|3> <deemph 0|1>  — 设根端口目标链路速率与 Gen2 可选去加重(0=-6dB,1=-3.5dB)，再触发重训练，ASPM 保持关闭
D=/sys/bus/pci/devices/0002:21:00.0; R=/sys/bus/pci/devices/0002:20:00.0
wb() { printf "$(printf '\%03o' $3)" | dd of=$1/config bs=1 seek=$2 count=1 conv=notrunc 2>/dev/null; }
v=$(( $1 | ($2 << 6) ))
wb $R 160 $v; wb $R 161 0          # LnkCtl2 @0xa0
wb $R 128 96; wb $R 129 0          # LnkCtl @0x80: ASPM off + Retrain Link(bit5)
sleep 3
wb $R 128 64; wb $D 128 72         # 清重训练位，两端 ASPM 关闭
rd16() { od -An -tx2 -j$2 -N2 $1/config | tr -d ' '; }
echo "link=$(cat $D/current_link_speed)/x$(cat $D/current_link_width)  root LnkCtl2=0x$(rd16 $R 160) LnkSta2=0x$(rd16 $R 162) | ep LnkSta2=0x$(rd16 $D 162)"
