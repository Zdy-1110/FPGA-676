#!/bin/bash
# 20261018 ddr hub: rt_ddr_hub simulation script (Questa)
cd /d/pango_build/4_15_PCIE_DMA/sim_ddr

QUESTA=/d/Questa/questa_fse/win64
LOG=sim.log

rm -rf work
: > $LOG

echo "=== vlib ===" >> $LOG
$QUESTA/vlib.exe work >> $LOG 2>&1
vlib_rc=$?

echo "=== vlog ===" >> $LOG
$QUESTA/vlog.exe -sv +incdir+. -work work \
    ../src/ddr/rt_ddr_hub.v \
    tb_ddr_hub.v >> $LOG 2>&1
vlog_rc=$?

echo "=== vsim ===" >> $LOG
$QUESTA/vsim.exe -c -work work tb_ddr_hub -do "run -all; quit -f" >> $LOG 2>&1
vsim_rc=$?

echo "vlib rc=$vlib_rc  vlog rc=$vlog_rc  vsim rc=$vsim_rc"

if grep -q "ALL TESTS PASSED" $LOG; then
    exit 0
else
    exit 1
fi
