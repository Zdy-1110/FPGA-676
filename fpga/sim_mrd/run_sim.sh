#!/bin/bash
# 20261018 mrd: long MRd simulation script (Questa)
cd /d/pango_build/4_15_PCIE_DMA/sim_mrd

QUESTA=/d/Questa/questa_fse/win64
LOG=sim.log

rm -rf work
: > $LOG

echo "=== vlib ===" >> $LOG
$QUESTA/vlib.exe work >> $LOG 2>&1
vlib_rc=$?

echo "=== vlog ===" >> $LOG
$QUESTA/vlog.exe -work work \
    ../src/dma_src/tx/rt0202_dma_mrd_ctrl.v \
    ../src/dma_src/rx/rt0102_dma_cpld_tag_ctrl.v \
    ../src/dma_src/rx/ipm_distributed_sdpram_v1_2.v \
    ../src/dma_src/rx/rt0103_dma_data_wr_ctrl.v \
    ../src/dma_src/rx/rt01_dma_rx.v \
    ../src/dma_src/rt_dma.v \
    tb_mrd_long.v >> $LOG 2>&1
vlog_rc=$?

echo "=== vsim ===" >> $LOG
$QUESTA/vsim.exe -c -work work tb_mrd_long -do "run -all; quit -f" >> $LOG 2>&1
vsim_rc=$?

echo "vlib rc=$vlib_rc  vlog rc=$vlog_rc  vsim rc=$vsim_rc"
exit $vsim_rc
