#!/bin/bash
set -e
cd "$(dirname "$0")"

# Ensure reference hex files exist
python gen_ref_hex.py

vlib work > /dev/null 2>&1 || true
vlog -sv ../src/disp/rt_lane_det.v tb_lane_thr.sv

echo "============================================================"
echo "RUNNING 5-SEGMENT LANE RTL REGRESSION (DEFAULT THRESHOLD = 61)"
echo "============================================================"

all_pass=1

for seg in seg_A_solid seg_B_dashed seg_C_double_yellow seg_board seg_recover; do
    echo "--- Testing $seg ---"
    vsim -c -t 1ps work.tb_lane_thr +SEG=$seg -do "run -all; quit -f" > sim_${seg}.log 2>&1
    rc=$?
    res_line=$(grep "SEG $seg:" sim_${seg}.log || true)
    echo "$res_line (exit_code: $rc)"
    if echo "$res_line" | grep -q "row_mismatch=0 frame_field_mismatch=0"; then
        echo "  [PASS] $seg"
    else
        echo "  [FAIL] $seg"
        all_pass=0
    fi
done

echo ""
echo "============================================================"
echo "RUNNING THRESHOLD solid_rows=120 TESTS"
echo "============================================================"

echo "--- seg_B_dashed (default 61 statistics) ---"
vsim -c -t 1ps work.tb_lane_thr +SEG=seg_B_dashed +SOLID_ROWS=61 -do "run -all; quit -f" > sim_seg_B_thr61.log 2>&1
grep "SEG seg_B_dashed" sim_seg_B_thr61.log || true

echo "--- seg_B_dashed (solid_rows=120 statistics) ---"
vsim -c -t 1ps work.tb_lane_thr +SEG=seg_B_dashed +SOLID_ROWS=120 -do "run -all; quit -f" > sim_seg_B_thr120.log 2>&1
grep "SEG seg_B_dashed" sim_seg_B_thr120.log || true

echo "--- seg_A_solid (default 61 statistics) ---"
vsim -c -t 1ps work.tb_lane_thr +SEG=seg_A_solid +SOLID_ROWS=61 -do "run -all; quit -f" > sim_seg_A_thr61.log 2>&1
grep "SEG seg_A_solid" sim_seg_A_thr61.log || true

echo "--- seg_A_solid (solid_rows=120 statistics) ---"
vsim -c -t 1ps work.tb_lane_thr +SEG=seg_A_solid +SOLID_ROWS=120 -do "run -all; quit -f" > sim_seg_A_thr120.log 2>&1
grep "SEG seg_A_solid" sim_seg_A_thr120.log || true

echo ""
if [ $all_pass -eq 1 ]; then
    echo "ALL 5 DEFAULT SEGMENTS PASSED: row_mismatch=0 frame_field_mismatch=0"
    exit 0
else
    echo "REGRESSION FAILED!"
    exit 1
fi
