open_project D:/pango_build/4_15_PCIE_DMA/pnr/pg2l_pcie_dma.pds
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/disp/rt_disp_win_reader.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/disp/rt_disp_win_reader_rgb.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/disp/rt_disp_stats.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/disp/rt_lane_det.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/disp/rt_zebra_det.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/disp/rt_night.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/disp/rt_zoom_ana.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/cam/cmos_8_16bit.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/cam/i2c_com.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/cam/power_on_delay.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/cam/reg_config.v -verilog} err]} { puts "add_design skipped: $err" }
if {[catch {add_design D:/pango_build/4_15_PCIE_DMA/src/cam/cam_ddr_writer.v -verilog} err]} { puts "add_design skipped: $err" }
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
compile -top_module pango_pcie_dma_top -force_to_run
synthesize -ads -selected_syn_tool_opt 2 -force_to_run
dev_map -force_to_run
pnr -planning_before_place Enable -force_to_run -gplace_times 1 -seed_step 1 -gplace_times 6 -pick_first_timing_convergence_seed FALSE
report_timing
gen_bit_stream -master_configuration_clock_frequency {25M} -force_to_run
file copy -force D:/pango_build/4_15_PCIE_DMA/pnr/prj_tasks/pnr_1/generate_bitstream/pango_pcie_dma_top.sbit D:/pango_work/quad/out/quad_cam23.sbit
file mkdir D:/pango_work/quad/out/cam23_reports
if {[file exists D:/pango_build/4_15_PCIE_DMA/pnr/prj_tasks/pnr_1/place_route/multiseed_result.csv]} {
    file copy -force D:/pango_build/4_15_PCIE_DMA/pnr/prj_tasks/pnr_1/place_route/multiseed_result.csv D:/pango_work/quad/out/cam23_reports/multiseed_result.csv
}
if {[file exists D:/pango_build/4_15_PCIE_DMA/pnr/prj_tasks/pnr_1/report_timing/pango_pcie_dma_top.rtr]} {
    file copy -force D:/pango_build/4_15_PCIE_DMA/pnr/prj_tasks/pnr_1/report_timing/pango_pcie_dma_top.rtr D:/pango_work/quad/out/cam23_reports/pango_pcie_dma_top.rtr
}
if {[file exists D:/pango_build/4_15_PCIE_DMA/pnr/prj_tasks/pnr_1/device_map/pango_pcie_dma_top.dmr]} {
    file copy -force D:/pango_build/4_15_PCIE_DMA/pnr/prj_tasks/pnr_1/device_map/pango_pcie_dma_top.dmr D:/pango_work/quad/out/cam23_reports/pango_pcie_dma_top.dmr
}
puts "=== quad_cam23.sbit and reports copied successfully ==="
