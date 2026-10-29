#!/bin/sh
# board_npu_freq.sh - NPU devfreq sweep & temperature benchmark tool for RK3568 board Linux
#
# Usage:
#   board_npu_freq.sh <model.rknn> [input_file]
#
# Features:
#   1. Detects NPU devfreq node under /sys/class/devfreq
#   2. Backs up original governor and automatically restores it upon exit or interruption (trap)
#   3. Switches governor to userspace and sweeps all available frequencies from lowest to highest
#   4. For each frequency: settles 0.5s, measures thermal temperature, runs npu_bench (--zero-copy, 100 iters)
#   5. Extracts average run latency and FPS, outputs formatted summary table

set -e

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 <model.rknn> [input_file]"
    echo ""
    echo "Arguments:"
    echo "  <model.rknn>   Path to RKNN model file (required)"
    echo "  [input_file]   Path to test input file (optional, e.g. 960x320 RGB raw)"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    exit 0
fi

if [ $# -lt 1 ]; then
    echo "Error: missing model.rknn argument." >&2
    echo "Usage: $0 <model.rknn> [input_file]" >&2
    exit 1
fi

MODEL_FILE="$1"
INPUT_FILE="$2"

if [ ! -f "$MODEL_FILE" ]; then
    echo "Error: model file '$MODEL_FILE' does not exist." >&2
    exit 1
fi

if [ -n "$INPUT_FILE" ] && [ ! -f "$INPUT_FILE" ]; then
    echo "Error: input file '$INPUT_FILE' does not exist." >&2
    exit 1
fi

# Locate NPU devfreq directory
NPU_DEV=""
for d in /sys/class/devfreq/*npu* /sys/class/devfreq/fde40000.npu; do
    if [ -d "$d" ]; then
        NPU_DEV="$d"
        break
    fi
done

if [ -z "$NPU_DEV" ]; then
    echo "Error: NPU devfreq directory not found under /sys/class/devfreq" >&2
    exit 1
fi

# Locate npu_bench binary
BENCH_BIN="/tmp/npu_bench"
if [ ! -x "$BENCH_BIN" ]; then
    if [ -x "./npu_bench" ]; then
        BENCH_BIN="./npu_bench"
    elif [ -x "$(dirname "$0")/npu_bench" ]; then
        BENCH_BIN="$(dirname "$0")/npu_bench"
    elif command -v npu_bench >/dev/null 2>&1; then
        BENCH_BIN="$(command -v npu_bench)"
    else
        echo "Error: npu_bench executable not found at /tmp/npu_bench, ./npu_bench or PATH" >&2
        exit 1
    fi
fi

# Read and save original settings
ORIG_GOV=$(cat "$NPU_DEV/governor" 2>/dev/null || echo "")
ORIG_MIN_FREQ=$(cat "$NPU_DEV/min_freq" 2>/dev/null || echo "")
ORIG_MAX_FREQ=$(cat "$NPU_DEV/max_freq" 2>/dev/null || echo "")

cleanup() {
    trap - EXIT INT TERM
    echo ""
    echo "=== Restoring NPU devfreq settings ==="
    if [ -n "$ORIG_MIN_FREQ" ] && [ -w "$NPU_DEV/min_freq" ]; then
        echo "$ORIG_MIN_FREQ" > "$NPU_DEV/min_freq" 2>/dev/null || true
    fi
    if [ -n "$ORIG_MAX_FREQ" ] && [ -w "$NPU_DEV/max_freq" ]; then
        echo "$ORIG_MAX_FREQ" > "$NPU_DEV/max_freq" 2>/dev/null || true
    fi
    if [ -n "$ORIG_GOV" ] && [ -w "$NPU_DEV/governor" ]; then
        echo "$ORIG_GOV" > "$NPU_DEV/governor" 2>/dev/null || true
    fi
    REST_GOV=$(cat "$NPU_DEV/governor" 2>/dev/null || echo "unknown")
    REST_FREQ=$(cat "$NPU_DEV/cur_freq" 2>/dev/null || echo "unknown")
    echo "Restoration confirmed: governor=$REST_GOV, cur_freq=$REST_FREQ"
}

trap cleanup EXIT INT TERM

echo "================ NPU Devfreq Info ================"
echo "Devfreq node:          $NPU_DEV"
echo "Original governor:     ${ORIG_GOV:-unknown}"
if [ -f "$NPU_DEV/available_governors" ]; then
    echo "Available governors:   $(cat "$NPU_DEV/available_governors")"
fi
if [ -f "$NPU_DEV/available_frequencies" ]; then
    echo "Available frequencies: $(cat "$NPU_DEV/available_frequencies")"
fi
echo "Benchmark binary:      $BENCH_BIN"
echo "Model file:            $MODEL_FILE"
echo "Input file:            ${INPUT_FILE:-(zero buffer)}"
echo "=================================================="

# Switch governor to userspace
if grep -q "userspace" "$NPU_DEV/available_governors" 2>/dev/null; then
    echo "userspace" > "$NPU_DEV/governor" 2>/dev/null || true
else
    echo "Warning: 'userspace' governor not found in available_governors; attempting fallback" >&2
fi
CUR_GOV=$(cat "$NPU_DEV/governor" 2>/dev/null || echo "unknown")
echo "Active governor:       $CUR_GOV"

set_frequency() {
    f=$1
    if [ -w "$NPU_DEV/userspace/set_freq" ]; then
        echo "$f" > "$NPU_DEV/userspace/set_freq" 2>/dev/null || true
    elif [ -w "$NPU_DEV/set_freq" ]; then
        echo "$f" > "$NPU_DEV/set_freq" 2>/dev/null || true
    fi

    # Also clamp min_freq/max_freq as compatibility fallback
    if [ -w "$NPU_DEV/max_freq" ] && [ -w "$NPU_DEV/min_freq" ]; then
        echo "$f" > "$NPU_DEV/max_freq" 2>/dev/null || true
        echo "$f" > "$NPU_DEV/min_freq" 2>/dev/null || true
        echo "$f" > "$NPU_DEV/max_freq" 2>/dev/null || true
    fi
}

get_temp() {
    tz_file=""
    for tz in /sys/class/thermal/thermal_zone*; do
        if [ -d "$tz" ]; then
            type=$(cat "$tz/type" 2>/dev/null || echo "")
            case "$type" in
                *npu*|*soc*)
                    tz_file="$tz/temp"
                    break
                    ;;
            esac
        fi
    done
    if [ -z "$tz_file" ] && [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        tz_file="/sys/class/thermal/thermal_zone0/temp"
    fi
    if [ -n "$tz_file" ] && [ -f "$tz_file" ]; then
        raw=$(cat "$tz_file" 2>/dev/null || echo "")
        case "$raw" in
            ""|*[!0-9]*)
                echo "N/A"
                ;;
            *)
                t_int=$((raw / 1000))
                t_dec=$(( (raw % 1000) / 100 ))
                echo "${t_int}.${t_dec}"
                ;;
        esac
    else
        echo "N/A"
    fi
}

# Collect and sort frequencies in ascending order
FREQS=""
if [ -f "$NPU_DEV/available_frequencies" ]; then
    FREQS=$(tr ' ' '\n' < "$NPU_DEV/available_frequencies" 2>/dev/null | grep '^[0-9]' | sort -n || true)
fi
if [ -z "$FREQS" ]; then
    FREQS=$(cat "$NPU_DEV/cur_freq" 2>/dev/null || echo "")
fi
if [ -z "$FREQS" ]; then
    echo "Error: unable to determine available NPU frequencies." >&2
    exit 1
fi

echo ""
printf "%-12s %-14s %-10s %-16s %-10s\n" "Target(MHz)" "Actual(MHz)" "Temp(C)" "Avg Run (ms)" "FPS"
printf "%-12s %-14s %-10s %-16s %-10s\n" "-----------" "-----------" "-------" "------------" "---"

for freq in $FREQS; do
    set_frequency "$freq"
    sleep 0.5 2>/dev/null || sleep 1

    actual_hz=$(cat "$NPU_DEV/cur_freq" 2>/dev/null || echo "")
    case "$actual_hz" in
        ""|*[!0-9]*)
            actual_mhz="N/A"
            ;;
        *)
            actual_mhz=$((actual_hz / 1000000))
            ;;
    esac

    target_mhz=$((freq / 1000000))
    temp_c=$(get_temp)

    if [ -n "$INPUT_FILE" ]; then
        out=$("$BENCH_BIN" --zero-copy --iters 100 "$MODEL_FILE" "$INPUT_FILE" 2>&1 || true)
    else
        out=$("$BENCH_BIN" --zero-copy --iters 100 "$MODEL_FILE" 2>&1 || true)
    fi

    avg_ms=$(echo "$out" | grep 'run:' | sed -n 's/.*avg = *\([0-9.]*\) *ms.*/\1/p' | head -n 1)
    fps_val=$(echo "$out" | grep 'FPS:' | sed -n 's/.*FPS: *\([0-9.]*\) *fps.*/\1/p' | head -n 1)

    [ -z "$avg_ms" ] && avg_ms="FAIL"
    [ -z "$fps_val" ] && fps_val="FAIL"

    printf "%-12s %-14s %-10s %-16s %-10s\n" "$target_mhz" "$actual_mhz" "$temp_c" "$avg_ms" "$fps_val"
done
