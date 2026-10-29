#!/bin/sh
E=/sys/bus/pci/devices/0002:21:00.0
[ -e "$E" ] && { echo 1 > "$E/enable"; printf '\006' | dd of="$E/config" bs=1 seek=4 count=1 conv=notrunc 2>/dev/null; }
cd /userdata/quad
while :; do
  sel=$(./mode_select --bar1 0xf0204000 --dir /userdata/quad/menu); rc=$?
  [ $rc -ne 0 ] && exit 0
  case "$sel" in
    0) ./menu_daemon --bar1 0xf0204000 ;;
    1) ./usb_menu --bar1 0xf0204000 ;;
  esac
done
