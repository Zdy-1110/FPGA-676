#!/bin/bash
# HDMI (MS7210/MS7200) bring-up / re-init / NACK stat verification (Questa)
cd /d/pango_build/4_15_PCIE_DMA/sim_ms72

QUESTA=/d/Questa/questa_fse/win64
LOG=hdmi_sim.log
: > $LOG

echo "=== vlib/vlog HDMI ===" >> $LOG
rm -rf work_hdmi
$QUESTA/vlib.exe work_hdmi >> $LOG 2>&1
$QUESTA/vlog.exe -sv -suppress 2388 -work work_hdmi \
    ../src/disp/iic_dri.v \
    ../src/disp/ms7200_ctl.v \
    ../src/disp/ms7210_ctl.v \
    ../src/disp/ms72xx_ctl.v \
    ../src/disp/rt_ext_regs.v \
    tb_hdmi.sv >> $LOG 2>&1
VLOG_RC=$?

echo "=== vsim HDMI ===" >> $LOG
$QUESTA/vsim.exe -c -work work_hdmi tb_hdmi -do "run -all; quit -f" >> $LOG 2>&1
VSIM_RC=$?

if [ $VLOG_RC -ne 0 ]; then
    echo "VLOG FAILED (rc=$VLOG_RC)"
    exit 1
fi

if grep -q "ALL HDMI TESTS PASSED" $LOG; then
    echo "HDMI SIM PASS"
    exit 0
else
    echo "HDMI SIM FAIL (vsim rc=$VSIM_RC)"
    exit 1
fi
