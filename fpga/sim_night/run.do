vlib work
vlog +incdir+../src/disp ../src/disp/rt_night.v tb_rt_night.v
vsim -c -t 1ps work.tb_rt_night
run -all
quit -f
