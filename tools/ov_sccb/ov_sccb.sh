#!/bin/sh
# tools/ov_sccb/ov_sccb.sh - Write OV5640 registers via FPGA BAR1 SCCB runtime interface
set -e

BAR1="0xf0204000"
DRY_RUN=0
FILE=""
DEVMEM_BIN="${DEVMEM:-devmem}"

usage() {
    echo "Usage: $0 [-b BAR1] [-n] (-f FILE | REG VAL [REG VAL ...])" >&2
    exit 1
}

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -b)
            [ $# -lt 2 ] && usage
            BAR1="$2"
            shift 2
            ;;
        -n)
            DRY_RUN=1
            shift
            ;;
        -f)
            [ $# -lt 2 ] && usage
            FILE="$2"
            shift 2
            ;;
        -*)
            usage
            ;;
        *)
            break
            ;;
    esac
done

ADDR_838=$(printf "0x%X" $((BAR1 + 0x838)))
ADDR_8F8=$(printf "0x%X" $((BAR1 + 0x8F8)))
ADDR_8FC=$(printf "0x%X" $((BAR1 + 0x8FC)))

# Validation regex patterns
# REG: 0x followed by 1 to 4 hex digits
# VAL: 0x followed by 1 to 2 hex digits
# SLEEP_MS: 1 to 5 decimal digits
is_valid_reg() {
    echo "$1" | grep -Eq '^[0][xX][0-9a-fA-F]{1,4}$'
}

is_valid_val() {
    echo "$1" | grep -Eq '^[0][xX][0-9a-fA-F]{1,2}$'
}

is_valid_sleep_ms() {
    echo "$1" | grep -Eq '^[0-9]{1,5}$'
}

# Read register with error checking
read_reg32() {
    addr="$1"
    raw=$($DEVMEM_BIN "$addr" 32 2>/dev/null) || {
        echo "Error: failed to read $addr via $DEVMEM_BIN" >&2
        return 1
    }
    # Check if raw is a valid hex integer
    if ! echo "$raw" | grep -Eq '^[0][xX][0-9a-fA-F]+$'; then
        echo "Error: invalid response from devmem $addr: '$raw'" >&2
        return 1
    fi
    echo "$raw"
    return 0
}

# 1. Check bitstream version: BAR1 + 0x838 >= 0x20261106
if ! VER_VAL=$(read_reg32 "$ADDR_838"); then
    echo "Error: failed to read FPGA bitstream version at $ADDR_838" >&2
    exit 4
fi

VER_NUM=$(printf "%d" "$VER_VAL" 2>/dev/null || echo 0)
REQ_NUM=$((0x20261106))

if [ "$VER_NUM" -lt "$REQ_NUM" ]; then
    echo "Error: FPGA bitstream version ($VER_VAL) is lower than required (0x20261106)" >&2
    exit 4
fi

# 2. Collect operations to execute
# Format of ops list: "WRITE <REG> <VAL>" or "SLEEP <MS>"
TMP_OPS=""

sleep_ms() {
    ms="$1"
    if command -v usleep >/dev/null 2>&1; then
        usleep "$((ms * 1000))" 2>/dev/null || true
    elif command -v sleep >/dev/null 2>&1; then
        if sleep 0.001 2>/dev/null; then
            sec=$(awk "BEGIN {printf \"%.4f\", $ms/1000}" 2>/dev/null || echo "")
            if [ -n "$sec" ]; then
                sleep "$sec"
            else
                sleep 1
            fi
        else
            sec=$(( (ms + 999) / 1000 ))
            sleep "$sec"
        fi
    else
        loops=$((ms * 2000))
        k=0
        while [ $k -lt $loops ]; do
            k=$((k + 1))
        done
    fi
}

if [ -n "$FILE" ]; then
    if [ ! -f "$FILE" ]; then
        echo "Error: file '$FILE' not found" >&2
        exit 1
    fi
    line_num=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))
        # Strip comments
        clean=$(echo "$line" | sed 's/#.*//')
        # Trim leading/trailing whitespace
        clean=$(echo "$clean" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$clean" ] && continue

        # Check line syntax
        set -- $clean
        if [ "$1" = "sleep_ms" ]; then
            if [ $# -ne 2 ] || ! is_valid_sleep_ms "$2"; then
                echo "Error: invalid syntax at line $line_num: '$line'" >&2
                exit 1
            fi
            ms_val="$2"
            TMP_OPS="${TMP_OPS}SLEEP $ms_val
"
        elif [ $# -eq 2 ]; then
            if ! is_valid_reg "$1" || ! is_valid_val "$2"; then
                echo "Error: invalid syntax at line $line_num: '$line'" >&2
                exit 1
            fi
            r_val=$(printf "0x%04X" "$1")
            v_val=$(printf "0x%02X" "$2")
            TMP_OPS="${TMP_OPS}WRITE $r_val $v_val
"
        else
            echo "Error: invalid syntax at line $line_num: '$line'" >&2
            exit 1
        fi
    done < "$FILE"
else
    if [ $# -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
        echo "Error: REG VAL pairs required (even number of arguments)" >&2
        exit 1
    fi
    arg_idx=1
    while [ $# -gt 0 ]; do
        if ! is_valid_reg "$1" || ! is_valid_val "$2"; then
            echo "Error: invalid syntax at arguments $arg_idx-$((arg_idx + 1)): '$1 $2'" >&2
            exit 1
        fi
        r_val=$(printf "0x%04X" "$1")
        v_val=$(printf "0x%02X" "$2")
        TMP_OPS="${TMP_OPS}WRITE $r_val $v_val
"
        shift 2
        arg_idx=$((arg_idx + 2))
    done
fi

# 3. Helper to poll busy==0
wait_busy_zero() {
    retry=0
    while [ $retry -lt 500 ]; do
        if ! s=$(read_reg32 "$ADDR_8FC"); then
            echo "Error: failed to read $ADDR_8FC" >&2
            return 2
        fi
        s_num=$(printf "%d" "$s" 2>/dev/null || echo 0)
        busy=$((s_num & 1))
        if [ "$busy" -eq 0 ]; then
            echo "$s_num"
            return 0
        fi
        retry=$((retry + 1))
    done
    return 1
}

# 4. Helper to poll busy==0 and done_cnt changed
wait_done() {
    old_done="$1"
    retry=0
    while [ $retry -lt 500 ]; do
        if ! s=$(read_reg32 "$ADDR_8FC"); then
            echo "Error: failed to read $ADDR_8FC" >&2
            return 2
        fi
        s_num=$(printf "%d" "$s" 2>/dev/null || echo 0)
        busy=$((s_num & 1))
        cur_done=$(( (s_num >> 16) & 0xFFFF ))
        if [ "$busy" -eq 0 ] && [ "$cur_done" -ne "$old_done" ]; then
            echo "$s_num"
            return 0
        fi
        retry=$((retry + 1))
    done
    return 1
}

# 5. Process each operation
written_cnt=0
nack_cnt=0

while IFS= read -r op; do
    [ -z "$op" ] && continue
    set -- $op
    if [ "$1" = "SLEEP" ]; then
        ms="$2"
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[DRY-RUN] sleep_ms $ms"
        else
            sleep_ms "$ms"
        fi
    elif [ "$1" = "WRITE" ]; then
        reg="$2"
        val="$3"
        reg_num=$(printf "%d" "$reg")
        val_num=$(printf "%d" "$val")
        cmd_word=$(printf "0x%08X" $(( (reg_num << 8) | val_num )))

        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[DRY-RUN] write reg=$reg val=$val (word=$cmd_word)"
        else
            # Wait busy == 0
            rc_busy=0
            stat_pre=$(wait_busy_zero) || rc_busy=$?
            if [ $rc_busy -ne 0 ]; then
                if [ $rc_busy -eq 2 ]; then
                    echo "Error: devmem read error while waiting for busy==0 before writing $reg" >&2
                else
                    echo "Error: timeout waiting for busy==0 before writing $reg" >&2
                fi
                exit 2
            fi
            old_done=$(( (stat_pre >> 16) & 0xFFFF ))

            # Write 0x8F8
            if ! $DEVMEM_BIN "$ADDR_8F8" 32 "$cmd_word" 2>/dev/null; then
                echo "Error: failed to write $cmd_word to $ADDR_8F8" >&2
                exit 2
            fi

            # Wait busy == 0 and done_cnt != old_done
            rc_done=0
            stat_post=$(wait_done "$old_done") || rc_done=$?
            if [ $rc_done -ne 0 ]; then
                if [ $rc_done -eq 2 ]; then
                    echo "Error: devmem read error while waiting for completion of writing $reg" >&2
                else
                    echo "Error: timeout waiting for completion of writing $reg" >&2
                fi
                exit 2
            fi

            # Check last_nack (bit 1)
            last_nack=$(( (stat_post >> 1) & 1 ))
            if [ "$last_nack" -ne 0 ]; then
                echo "NACK writing register $reg"
                nack_cnt=$((nack_cnt + 1))
            fi
        fi
        written_cnt=$((written_cnt + 1))
    fi
done << EOF
$TMP_OPS
EOF

echo "写入 $written_cnt 笔，NACK $nack_cnt 笔"
if [ "$nack_cnt" -gt 0 ]; then
    exit 3
fi
exit 0
