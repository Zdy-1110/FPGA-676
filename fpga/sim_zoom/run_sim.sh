#!/bin/bash
set -e
cd "$(dirname "$0")"

vlib work > /dev/null 2>&1 || true
vlog -sv +incdir+../src/disp \
    ../src/disp/sync_vg.v \
    ../src/disp/font8x16_rom.v \
    ../src/disp/arrow24_rom.v \
    ../src/disp/rt_osd.v \
    ../src/disp/rt_disp_win_reader_rgb.v \
    ref_reader_rgb.v \
    ../src/disp/rt_zoom_ana.v \
    tb_zoom.sv

vsim -c -t 1ps work.tb_zoom -do "run -all; quit -f" | tee sim.log

if grep -q "ZOOM_TB PASS" sim.log; then
    echo "SIMULATION SUCCESS: ZOOM_TB PASS"
    exit 0
else
    echo "SIMULATION FAILED"
    exit 1
fi
