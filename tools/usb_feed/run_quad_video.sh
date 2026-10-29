#!/bin/sh
# run_quad_video.sh <bar1_hex> <素材目录或 4 个 mp4 路径> [额外 usb_feed 参数]
set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <bar1_hex> <素材目录或 4 个 mp4 路径> [额外 usb_feed 参数]" >&2
    exit 1
fi

BAR1=$1
shift

case "$BAR1" in
    0x*|0X*) ;;
    *) BAR1="0x$BAR1" ;;
esac

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
USB_FEED="${USB_FEED:-$SCRIPT_DIR/usb_feed}"
NPU_MODEL="${NPU_MODEL:-$SCRIPT_DIR/b5_v6n_band.rknn}"

if [ -d "$1" ]; then
    DIR=$1
    shift
    MP4_LIST=""
    for f in "$DIR"/*.mp4; do
        if [ -f "$f" ]; then
            MP4_LIST="$MP4_LIST $f"
        fi
    done
    if [ -z "$MP4_LIST" ]; then
        echo "error: no .mp4 files found in $DIR" >&2
        exit 1
    fi
    # largest files first, so a directory with >4 clips does not pick a few-second one
    SORTED_MP4=$(for f in $MP4_LIST; do echo "$(stat -L -c %s "$f") $f"; done | sort -rn | cut -d' ' -f2-)
    COUNT=0
    for f in $SORTED_MP4; do
        COUNT=$((COUNT + 1))
        eval "M$COUNT=\"\$f\""
    done
    if [ "$COUNT" -eq 1 ]; then
        V0=$M1; V1=$M1; V2=$M1; V3=$M1
    elif [ "$COUNT" -eq 2 ]; then
        V0=$M1; V1=$M2; V2=$M1; V3=$M2
    elif [ "$COUNT" -eq 3 ]; then
        V0=$M1; V1=$M2; V2=$M3; V3=$M1
    else
        V0=$M1; V1=$M2; V2=$M3; V3=$M4
    fi
    # usb_feed rejects the same path twice: give reused clips a symlink alias
    for i in 1 2 3; do
        eval "v=\$V$i"
        for j in $(seq 0 $((i - 1))); do
            eval "w=\$V$j"
            if [ "$v" = "$w" ]; then
                ln -sf "$v" /tmp/qv_slot$i.mp4
                eval "V$i=/tmp/qv_slot$i.mp4"
                break
            fi
        done
    done
else
    if [ $# -lt 4 ]; then
        echo "error: need either a directory containing .mp4 files or 4 .mp4 file paths" >&2
        exit 1
    fi
    V0=$1; V1=$2; V2=$3; V3=$4
    shift 4
fi

# 1. Check camera FIFO stuck on BAR1+0x8A4 ([19:10] >= 0x100)
ADDR_8A4=$(printf "0x%X" $((BAR1 + 0x8A4)))
VAL_8A4=$(devmem "$ADDR_8A4" 32)
FIFO_LEVEL=$(( (VAL_8A4 >> 10) & 0x3FF ))
if [ "$FIFO_LEVEL" -ge 256 ]; then
    echo "camera FIFO stuck (0x8A4=$VAL_8A4), reload bitstream" >&2
    exit 3
fi

# 2. Write 0x800=0x65
ADDR_800=$(printf "0x%X" $((BAR1 + 0x800)))
devmem "$ADDR_800" 32 0x65

# 3. Read-modify-write 0x880 |= 0x30
ADDR_880=$(printf "0x%X" $((BAR1 + 0x880)))
VAL_880=$(devmem "$ADDR_880" 32)
VAL_880_NEW=$(printf "0x%X" $((VAL_880 | 0x30)))
devmem "$ADDR_880" 32 "$VAL_880_NEW"

# 4. Launch usb_feed
exec "$USB_FEED" --bar1 "$BAR1" --dst 960x540 --slot0-rgb565 \
    --video "$V0:0:30" \
    --video "$V1:1:30" \
    --video "$V2:2:30" \
    --video "$V3:3:30" \
    --npu "$NPU_MODEL" "$@"
