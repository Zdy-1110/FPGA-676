#!/bin/sh
# pcicfg.sh r <bdf> <off> | w <bdf> <off> <val> — 32 位对齐读写 PCI 配置空间（off/val 可写 0x 前缀），经 sysfs 单次 dword 访问
F=/sys/bus/pci/devices/$2/config; O=$(($3))
if [ "$1" = w ]; then V=$(($4))
  printf "$(printf '\%03o\%03o\%03o\%03o' $((V & 255)) $(((V >> 8) & 255)) $(((V >> 16) & 255)) $(((V >> 24) & 255)))" > /tmp/pcicfg_w4.bin
  dd if=/tmp/pcicfg_w4.bin of=$F bs=4 seek=$((O / 4)) count=1 conv=notrunc 2>/dev/null
fi
printf '%s+0x%03x = 0x%08x\n' $2 $O $(od -An -tu4 -j$O -N4 $F | tr -d ' ')
