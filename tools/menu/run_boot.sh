#!/bin/sh
E=/sys/bus/pci/devices/0002:21:00.0
[ -e "$E" ] && { echo 1 > "$E/enable"; printf '\006' | dd of="$E/config" bs=1 seek=4 count=1 conv=notrunc 2>/dev/null; }
cd /userdata/quad
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
