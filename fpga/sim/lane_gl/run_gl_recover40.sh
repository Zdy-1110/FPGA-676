#!/bin/bash
Q=/d/Questa/questa_fse/win64
cd /d/pango_build/4_15_PCIE_DMA/sim/lane_gl
echo "=== $(date +%H:%M) seg_recover 40 frames gate-level"
$Q/vsim.exe -c -suppress 14408,16154 -t ps -do "run -all; quit -f" work_r6.tb_gl_board +SEG=seg_recover +NFRAMES=40 > gl_recover40.log 2>&1
echo "recover40_rc=$?"
grep -E "SEG |FRAME|Errors:" gl_recover40.log | tail -8
echo "=== $(date +%H:%M) DONE"
