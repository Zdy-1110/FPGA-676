#!/bin/bash
Q=/d/Questa/questa_fse/win64
cd /d/pango_build/4_15_PCIE_DMA/sim/lane_gl
echo "=== $(date +%H:%M) seg_board 2 frames"
$Q/vsim.exe -c -suppress 14408,16154 -t ps -do "run -all; quit -f" work_r6.tb_gl_board +SEG=seg_board +NFRAMES=2 > gl_board_r6.log 2>&1
echo "board_rc=$?"; grep -E "SEG |FRAME|Errors:" gl_board_r6.log | tail -6
if grep -q "SEG seg_board: row_mismatch=0 frame_field_mismatch=0" gl_board_r6.log; then
  echo "=== $(date +%H:%M) seg_recover 40 frames (long)"
  $Q/vsim.exe -c -suppress 14408,16154 -t ps -do "run -all; quit -f" work_r6.tb_gl_board +SEG=seg_recover +NFRAMES=40 > gl_recover_r6.log 2>&1
  echo "recover_rc=$?"; grep -E "SEG |Errors:" gl_recover_r6.log | tail -4
else
  echo "board gate-level FAILED or incomplete; skip recover"
fi
echo "=== $(date +%H:%M) DONE"
