#!/bin/sh
# tools/ov_sccb/mock_devmem.sh - Mock devmem utility for PC testing
# Usage: mock_devmem.sh ADDR [32 [VAL]]
#
# Environment variables:
#   MOCK_VER: Version returned by 0x838 (default: 0x20261106)
#   MOCK_NACK_REG: Register address (e.g. 0x3406) that triggers last_nack=1
#   MOCK_STATE_FILE: Path to state file (default: /tmp/mock_devmem_state.txt)

STATE_FILE="${MOCK_STATE_FILE:-/tmp/mock_devmem_state.txt}"
ADDR_IN="$1"
WIDTH="$2"
VAL_IN="$3"

# Initialize state if not present
if [ ! -f "$STATE_FILE" ]; then
    # Format: ver done_cnt nack_cnt last_nack last_cmd overrun busy
    # Default: ver=0x20261106, done_cnt=0, nack_cnt=0, last_nack=0, last_cmd=0, overrun=0, busy=0
    def_ver="${MOCK_VER:-0x20261106}"
    echo "$def_ver 0 0 0 0 0 0" > "$STATE_FILE"
fi

read -r s_ver s_done s_nack s_last_nack s_cmd s_overrun s_busy < "$STATE_FILE"

# If MOCK_VER is explicitly overridden in env, update s_ver
if [ -n "$MOCK_VER" ]; then
    s_ver="$MOCK_VER"
fi

# Normalize address
addr_norm=$(printf "0x%X" "$((ADDR_IN))" 2>/dev/null || echo "$ADDR_IN")

# If writing
if [ -n "$VAL_IN" ]; then
    val_num=$(printf "%d" "$VAL_IN" 2>/dev/null || echo 0)
    case "$addr_norm" in
        0xF02048F8)
            # Write SCCB command: (reg << 8) | val
            reg_addr=$(( (val_num >> 8) & 0xFFFF ))
            s_cmd=$(printf "0x%08X" "$val_num")
            s_done=$(( (s_done + 1) & 0xFFFF ))
            # Check if this reg should NACK
            trigger_nack=0
            if [ -n "$MOCK_NACK_REG" ]; then
                nack_num=$(printf "%d" "$MOCK_NACK_REG" 2>/dev/null || echo -1)
                if [ "$reg_addr" -eq "$nack_num" ]; then
                    trigger_nack=1
                fi
            fi
            if [ "$trigger_nack" -eq 1 ]; then
                s_last_nack=1
                s_nack=$(( (s_nack + 1) & 0xFF ))
            else
                s_last_nack=0
            fi
            s_busy=0
            ;;
        0xF02048FC)
            # Writing any value clears overrun
            s_overrun=0
            ;;
    esac
    echo "$s_ver $s_done $s_nack $s_last_nack $s_cmd $s_overrun $s_busy" > "$STATE_FILE"
    exit 0
fi

# If reading
if [ "$MOCK_FAIL_READ" = "1" ]; then
    echo "devmem: /dev/mem read error" >&2
    exit 1
fi
if [ "$MOCK_FAIL_REG_READ" = "1" ] && [ "$addr_norm" = "0xF02048FC" ]; then
    echo "devmem: /dev/mem read error" >&2
    exit 1
fi
case "$addr_norm" in
    0xF0204838)
        echo "$s_ver"
        ;;
    0xF02048F8)
        echo "$s_cmd"
        ;;
    0xF02048FC)
        # Construct 0x8FC:
        # bit0: busy
        # bit1: last_nack
        # bit2: cfg_done (1)
        # bit3: overrun
        # [15:8]: nack_cnt
        # [31:16]: done_cnt
        cfg_done=1
        stat=$(( (s_done << 16) | ((s_nack & 0xFF) << 8) | ((s_overrun & 1) << 3) | ((cfg_done & 1) << 2) | ((s_last_nack & 1) << 1) | (s_busy & 1) ))
        printf "0x%08X\n" "$stat"
        ;;
    *)
        echo "0x00000000"
        ;;
esac
exit 0
