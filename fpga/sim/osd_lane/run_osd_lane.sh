#!/bin/bash
set -e
cd /d/pango_build/4_15_PCIE_DMA/sim/osd_lane

QUESTA=/d/Questa/questa_fse/win64
WORK=work_osd

echo "=== Creating library $WORK ==="
rm -rf $WORK
$QUESTA/vlib $WORK

echo "=== Compiling RTL & TB ==="
$QUESTA/vlog -sv -work $WORK \
    ../../src/disp/font8x16_rom.v \
    ../../src/disp/arrow24_rom.v \
    ../../src/disp/rt_osd.v \
    tb_osd_lane.v

echo "=== Running Simulation ==="
$QUESTA/vsim -c -work $WORK tb_osd_lane -do "run -all; quit -f" 2>&1 | tee sim.log

if grep -q "ALL OSD LANE TESTS PASSED" sim.log; then
    echo "=== SIMULATION SUCCESS ==="
    exit 0
else
    echo "=== SIMULATION FAILED ==="
    exit 1
fi
