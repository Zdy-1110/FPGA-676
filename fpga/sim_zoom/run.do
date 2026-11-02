vlib work
vlog -sv +incdir+../src/disp ../src/disp/sync_vg.v ../src/disp/font8x16_rom.v ../src/disp/arrow24_rom.v ../src/disp/rt_osd.v ../src/disp/rt_disp_win_reader_rgb.v ref_reader_rgb.v ../src/disp/rt_zoom_ana.v tb_zoom.sv
vsim -c -t 1ps work.tb_zoom
run -all
quit -f
