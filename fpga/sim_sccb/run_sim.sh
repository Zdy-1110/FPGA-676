#!/bin/bash
set -e
cd "$(dirname "$0")"

vlib work > /dev/null 2>&1 || true

vlog -sv \
    +incdir+../src/disp \
    +incdir+../src/cam \
    ../src/cam/i2c_com.v \
    ../src/cam/reg_config.v \
    reg_config_orig.v \
    ../src/disp/rt_ext_regs.v \
    sccb_slave_model.v \
    tb_sccb.v

vsim -c -t 1ps -voptargs="+acc +initreg+0" work.tb_sccb -do "run -all; quit -f" | tee sim.log

if grep -q "SCCB_TB PASS" sim.log; then
    echo "SIMULATION SUCCESS: SCCB_TB PASS"
    exit 0
else
    echo "SIMULATION FAILED"
    exit 1
fi
