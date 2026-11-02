#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RTL_ARG="../src/disp/rt_lane_det.v"
REF_ARG="../sim_lane_thr/ref"
SEGS_ARG="seg_A_solid seg_B_dashed seg_C_double_yellow seg_board seg_recover"
EXTRA_VLOG_ARGS=()
EXTRA_VSIM_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rtl)
            RTL_ARG="$2"
            shift 2
            ;;
        --ref)
            REF_ARG="$2"
            shift 2
            ;;
        --segs)
            SEGS_ARG="$2"
            shift 2
            ;;
        +define+*)
            EXTRA_VLOG_ARGS+=("$1")
            shift
            ;;
        +*)
            EXTRA_VSIM_ARGS+=("$1")
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--rtl <path>] [--ref <path>] [--segs <\"seg1 seg2...\">] [+define+...] [+plusargs...]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Convert paths to Windows forward-slash paths
if [[ -f "$RTL_ARG" ]]; then
    RTL_WIN="$(cygpath -m "$RTL_ARG")"
else
    echo "ERROR: RTL file not found: $RTL_ARG"
    exit 1
fi

if [[ -d "$REF_ARG" ]]; then
    REF_WIN="$(cygpath -m "$REF_ARG")"
else
    echo "ERROR: Reference directory not found: $REF_ARG"
    exit 1
fi

echo "============================================================"
echo "PARALLEL LANE RTL REGRESSION"
echo "  RTL   : $RTL_WIN"
echo "  REF   : $REF_WIN"
echo "  SEGS  : $SEGS_ARG"
echo "============================================================"

# Prepare tb_lane_thr.sv in sim_lane_thr_par if not present
if [[ ! -f "$SCRIPT_DIR/tb_lane_thr.sv" ]]; then
    echo "Copying tb_lane_thr.sv from ../sim_lane_thr/ ..."
    cp "$SCRIPT_DIR/../sim_lane_thr/tb_lane_thr.sv" "$SCRIPT_DIR/tb_lane_thr.sv"
fi

IFS=' ' read -r -a SEG_LIST <<< "$SEGS_ARG"
TOTAL_START_TIME=$(date +%s)

declare -A SEG_PIDS
declare -A SEG_DIRS

# Step 1: Prepare directories and compile each work library
for seg in "${SEG_LIST[@]}"; do
    seg_dir="$SCRIPT_DIR/run_${seg}"
    mkdir -p "$seg_dir"
    cp -f "$SCRIPT_DIR/tb_lane_thr.sv" "$seg_dir/tb_lane_thr.sv"
    (
        cd "$seg_dir"
        vlib work > /dev/null 2>&1 || true
        vlog -sv "$RTL_WIN" tb_lane_thr.sv "${EXTRA_VLOG_ARGS[@]}" > vlog_${seg}.log 2>&1
    )
    vlog_rc=$?
    if [ $vlog_rc -ne 0 ]; then
        echo "ERROR: Compilation failed for $seg (exit code $vlog_rc). See $seg_dir/vlog_${seg}.log"
        exit 1
    fi
done

echo "Compilation finished for all segments. Launching parallel simulations..."

# Step 2: Launch parallel vsim instances
for seg in "${SEG_LIST[@]}"; do
    seg_dir="$SCRIPT_DIR/run_${seg}"
    SEG_DIRS["$seg"]="$seg_dir"
    (
        cd "$seg_dir"
        t0=$(date +%s)
        echo "$t0" > start_ts.txt
        vsim -c -t 1ps work.tb_lane_thr "+SEG=$seg" "+REF_DIR=$REF_WIN" "${EXTRA_VSIM_ARGS[@]}" -do "run -all; quit -f" > sim_${seg}.log 2>&1
        sim_rc=$?
        t1=$(date +%s)
        echo "$sim_rc" > exit_code.txt
        echo "$((t1 - t0))" > duration_sec.txt
    ) &
    SEG_PIDS["$seg"]=$!
    echo "  [STARTED] $seg (PID ${SEG_PIDS[$seg]})"
done

echo "Waiting for all parallel simulations to finish..."

# Step 3: Wait for all background simulations
for seg in "${SEG_LIST[@]}"; do
    wait "${SEG_PIDS[$seg]}" || true
    echo "  [FINISHED] $seg"
done

TOTAL_END_TIME=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END_TIME - TOTAL_START_TIME))

echo ""
echo "============================================================"
echo "REGRESSION RESULTS SUMMARY"
echo "============================================================"

all_passed=1

for seg in "${SEG_LIST[@]}"; do
    seg_dir="${SEG_DIRS[$seg]}"
    log_file="$seg_dir/sim_${seg}.log"
    dur_file="$seg_dir/duration_sec.txt"
    ec_file="$seg_dir/exit_code.txt"

    dur="unknown"
    if [[ -f "$dur_file" ]]; then
        dur="$(cat "$dur_file")s"
    fi

    ec="unknown"
    if [[ -f "$ec_file" ]]; then
        ec="$(cat "$ec_file")"
    fi

    res_line=$(grep "SEG $seg:" "$log_file" 2>/dev/null || true)
    if echo "$res_line" | grep -q "row_mismatch=0 frame_field_mismatch=0"; then
        status="PASS"
    else
        status="FAIL"
        all_passed=0
    fi

    printf "  %-24s: [%-4s] (duration: %-5s, exit: %-2s) %s\n" "$seg" "$status" "$dur" "$ec" "$res_line"
    
    # If failed, show license or error details if present
    if [ "$status" = "FAIL" ]; then
        if grep -q "License checkout has been disallowed" "$log_file" 2>/dev/null; then
            echo "    -> License conflict: only one session allowed to run nodelocked license."
        fi
    fi
done

echo "------------------------------------------------------------"
echo "Total wall-clock time: ${TOTAL_ELAPSED}s ($((TOTAL_ELAPSED / 60))m $((TOTAL_ELAPSED % 60))s)"

if [ $all_passed -eq 1 ]; then
    echo "ALL SEGMENTS PASSED: row_mismatch=0 frame_field_mismatch=0"
    exit 0
else
    echo "REGRESSION FAILED!"
    exit 1
fi
