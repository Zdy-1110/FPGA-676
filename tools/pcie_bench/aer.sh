#!/bin/sh
# aer.sh show|clear  — 读/清 RK 根端口与 FPGA 端点的 AER 状态 (UE@0x104, CE@0x110, 根口还有 RootErrSta@0x130)
R=/sys/bus/pci/devices/${RP:-0002:20:00.0}
E=/sys/bus/pci/devices/${EPDEV:-0002:21:00.0}
rd32() { od -An -tx4 -j$2 -N4 $1/config | tr -d ' '; }
case "$1" in
show)
  echo "root: UE=0x$(rd32 $R 260) CE=0x$(rd32 $R 272) RootErr=0x$(rd32 $R 304) | ep: UE=0x$(rd32 $E 260) CE=0x$(rd32 $E 272)"
  ;;
clear)
  for d in $R $E; do
    for off in 260 272; do printf '\377\377\377\377' | dd of=$d/config bs=1 seek=$off count=4 conv=notrunc 2>/dev/null; done
  done
  printf '\377\377\377\377' | dd of=$R/config bs=1 seek=304 count=4 conv=notrunc 2>/dev/null
  ;;
esac
