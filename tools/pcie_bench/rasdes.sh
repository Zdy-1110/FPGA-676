#!/bin/sh
# rasdes.sh on|off|clear|get <grp> <evt> <lane>|dump — 根端口 DWC RAS DES 事件计数器 (VSEC ID 2 @0x1a0)
R=/sys/bus/pci/devices/${RP:-0002:20:00.0}
VS=${VS:-0x1a0}; CTL=$((VS + 8)); DAT=$((VS + 12))
wr32() { printf "$(printf '\%03o\%03o\%03o\%03o' $(($2 & 255)) $((($2 >> 8) & 255)) $((($2 >> 16) & 255)) $((($2 >> 24) & 255)))" > /tmp/rasdes_w4.bin
         dd if=/tmp/rasdes_w4.bin of=$R/config bs=4 seek=$(($1 / 4)) count=1 conv=notrunc 2>/dev/null; }
rd32() { od -An -tu4 -j$1 -N4 $R/config | tr -d ' '; }
get() { wr32 $CTL $((($1 << 24) | ($2 << 16) | ($3 << 8))); rd32 $DAT; }
case "$1" in
on)    wr32 $CTL $((0x7 << 2)) ;;          # 所有事件计数使能
off)   wr32 $CTL $((0x5 << 2)) ;;
clear) wr32 $CTL 3 ;;                      # 所有计数清零
get)   get $2 $3 $4 ;;
dump)
  for l in 0 1; do
    echo "lane$l: ebuf_ovf=$(get 0 0 $l) ebuf_unf=$(get 0 1 $l) decode=$(get 0 2 $l) disparity=$(get 0 3 $l) rxvalid_deassert=$(get 0 6 $l) skp_add=$(get 4 0 $l) skp_del=$(get 4 1 $l)"
  done
  echo "common: ei_infer=$(get 1 5 0) rx_err=$(get 1 6 0) rx_recov_req=$(get 1 7 0) nfts_to=$(get 1 8 0) deskew=$(get 1 10 0)"
  echo "dll: bad_tlp=$(get 2 0 0) lcrc=$(get 2 1 0) bad_dllp=$(get 2 2 0) replay_roll=$(get 2 3 0) replay_to=$(get 2 4 0) rx_nak=$(get 2 5 0) tx_nak=$(get 2 6 0) retry_tlp=$(get 2 7 0)"
  echo "ltssm: l0_to_recov=$(get 5 0 0) l1_to_recov=$(get 5 1 0) speed_chg=$(get 5 12 0) width_chg=$(get 5 13 0)"
  ;;
esac
