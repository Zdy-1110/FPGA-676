add_design D:/pango_build/4_15_PCIE_DMA/src/disp/rt_lane_det.v -verilog
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
compile -top_module rt_lane_det -force_to_run
synthesize -ads -selected_syn_tool_opt 2 -force_to_run
