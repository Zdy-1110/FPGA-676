#!/bin/bash
# 20261018 osd1: rt_disp_reader / rt_ddr_rd_arb / rt_ext_regs / rt_keys /
#                rt_osd_ctl / rt_osd verification (Questa)
cd /d/pango_build/4_15_PCIE_DMA/sim_disp

QUESTA=/d/Questa/questa_fse/win64
PY=/e/Project/nesai2026/.venv_yolo/Scripts/python.exe
LOG=sim.log
: > $LOG

echo "=== vlib/vlog FULL ===" >> $LOG
rm -rf work_full work_small
$QUESTA/vlib.exe work_full >> $LOG 2>&1
$QUESTA/vlog.exe -sv -work work_full \
    ../src/disp/rt_disp_reader.v ../src/disp/rt_ddr_rd_arb.v \
    ../src/disp/rt_ext_regs.v ../src/disp/rt_keys.v \
    ../src/disp/rt_osd_ctl.v ../src/disp/rt_osd.v \
    ../src/disp/font8x16_rom.v ../src/disp/arrow24_rom.v \
    ../src/disp/sync_vg.v tb_disp.sv tb_osd.sv tb_keys.sv >> $LOG 2>&1
$QUESTA/vlog.exe -sv -work work_full ../src/dma_src/rx/rt0101_dma_request_ctrl.v \
    tb_ext.sv >> $LOG 2>&1

echo "=== vlib/vlog SMALL ===" >> $LOG
$QUESTA/vlib.exe work_small >> $LOG 2>&1
$QUESTA/vlog.exe -sv +define+SMALL -work work_small \
    ../src/disp/rt_disp_reader.v ../src/disp/rt_ddr_rd_arb.v \
    ../src/disp/rt_ext_regs.v ../src/disp/sync_vg.v tb_disp.sv >> $LOG 2>&1

fail=0
runtest() {
    tag=$1; lib=$2; top=$3; shift 3
    $QUESTA/vsim.exe -c -work $lib $top "$@" -do "run -all; quit -f" >> $LOG 2>&1
    if grep -q "$tag PASS" $LOG; then echo "$tag PASS"; else echo "$tag FAIL"; fail=1; fi
}

runtest T1 work_full  tb_disp +TEST=1 +CTRL=1    +DFILE=data/ddr_t1.hex +EFILE=data/exp_t1.hex +STRIDE=1920 +UVOFF=2073600
runtest T2 work_small tb_disp +TEST=2 +CTRL=4097 +DFILE=data/ddr_t2.hex +EFILE=data/exp_t2.hex +STRIDE=288  +UVOFF=36864
runtest T3 work_full  tb_disp +TEST=3 +CTRL=0    +DFILE=data/ddr_t4.hex +STRIDE=1920 +UVOFF=2073600
runtest T4 work_small tb_disp +TEST=4 +CTRL=1    +DFILE=data/ddr_t4.hex +EFILE=data/exp_t4.hex +STRIDE=256  +UVOFF=32768
runtest T5 work_small tb_disp +TEST=5 +CTRL=1    +DFILE=data/ddr_t4.hex +EFILE=data/exp_t4.hex +STRIDE=256  +UVOFF=32768
runtest T6 work_full  tb_ext
runtest T7 work_full  tb_osd +DFILE=data/ddr_t1.hex +EFILE=data/exp_t1.hex
runtest T8 work_full  tb_keys

# T7 frame -> PNG
if [ -f t7_frame.raw ]; then $PY raw2png.py t7_frame.raw t7_frame.png >> $LOG 2>&1; fi

if [ $fail -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
