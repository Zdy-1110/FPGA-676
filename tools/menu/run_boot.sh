#!/bin/sh
E=/sys/bus/pci/devices/0002:21:00.0
[ -e "$E" ] && { echo 1 > "$E/enable"; printf '\006' | dd of="$E/config" bs=1 seek=4 count=1 conv=notrunc 2>/dev/null; }
cd /userdata/quad
# 等 FPGA 从 flash 加载完成并应答 BAR1（整机冷启动时通常已就绪，这里兜底 10 s）
i=0
while [ $i -lt 10 ]; do
    v=$(devmem 0xf0204838 32 2>/dev/null)
    [ "$v" = "0x20261029" ] && break
    sleep 1
    i=$((i + 1))
done
[ "$v" = "0x20261029" ] || echo "warn: fpga version=$v after ${i}s" >> /tmp/run_boot.log
fail_cnt=0
while :; do
  sel=$(./mode_select --bar1 0xf0204000 --dir /userdata/quad/menu); rc=$?
  if [ $rc -ne 0 ]; then
    fail_cnt=$((fail_cnt + 1))
    if [ $fail_cnt -ge 3 ]; then
      echo "mode_select failed 3x" >> /tmp/run_boot.log
      exit 1
    fi
    pkill -x usb_feed
    pkill -x menu_daemon
    pkill -x usb_menu
    sleep 1
    continue
  fi
  fail_cnt=0
  case "$sel" in
    0) ./menu_daemon --bar1 0xf0204000 ;;
    1) ./usb_menu --bar1 0xf0204000 ;;
  esac
done
