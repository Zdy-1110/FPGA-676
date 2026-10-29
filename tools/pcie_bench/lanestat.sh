#!/bin/sh
# lanestat.sh — 读根端口 RAS DES SD_STATUS_L1LANE (VSEC+0xb0)：每 lane 的 deskew 指针/RxValid/电气空闲/极性
R=/sys/bus/pci/devices/0002:20:00.0; O=$((0x1a0 + 0xb0))
for l in 0 1; do
  printf "$(printf '\%03o\%03o\%03o\%03o' $l 0 0 0)" > /tmp/ls_w4.bin
  dd if=/tmp/ls_w4.bin of=$R/config bs=4 seek=$((O / 4)) count=1 conv=notrunc 2>/dev/null
  v=$(od -An -tu4 -j$O -N4 $R/config | tr -d ' ')
  echo "lane$l raw=$(printf %08x $v) deskew_ptr=$(((v >> 24) & 255)) txei=$(((v >> 20) & 1)) rxei=$(((v >> 19) & 1)) rxvalid=$(((v >> 18) & 1)) detect=$(((v >> 17) & 1)) rxpol=$(((v >> 16) & 1))"
done
