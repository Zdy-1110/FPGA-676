#!/bin/sh
cd "$(dirname "$0")" || exit 1

last=0
while true; do
    sel=$(./menu_launcher --bar1 0xf0204000 --dir /userdata/quad/menu --start "$last")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        exit "$rc"
    fi
    last="$sel"
    ./run_demo.sh "$sel"
done
