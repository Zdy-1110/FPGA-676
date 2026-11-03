# build_portable.tcl — cam23 位流便携构建脚本（只依赖仓库内相对路径）
#
# 用法（任选其一）：
#   pds_shell -f fpga/pnr/build_portable.tcl
#   PDS GUI 打开 fpga/pnr/pg2l_pcie_dma.pds 后在 Tcl 控制台 source 本文件
#
# 产物：
#   out/quad_cam23.sbit         预编译位流（可直接烧写）
#   out/cam23_reports/          时序 rtr / 资源 dmr / 多 seed 结果
#
# 约束：PDS 2025.2（build 211867），器件 PG2L100H-6FBG676。
# 说明：本脚本与 build_cam23.tcl 流程一致，仅把 D:/pango_build 绝对路径换成仓库相对路径。

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR [file normalize [file join $ROOT out]]
set PROJ [file join $SCRIPT_DIR pg2l_pcie_dma.pds]

if {![file exists $PROJ]} {
    error "project not found: $PROJ"
}
file mkdir $OUT_DIR
puts "=== root: $ROOT"

open_project $PROJ

# 工程文件未登记的源码（cam18/cam23 新增），相对仓库根目录逐个加入
foreach rel [list \
    "fpga/src/disp/rt_disp_win_reader.v" \
    "fpga/src/disp/rt_disp_win_reader_rgb.v" \
    "fpga/src/disp/rt_disp_stats.v" \
    "fpga/src/disp/rt_lane_det.v" \
    "fpga/src/disp/rt_zebra_det.v" \
    "fpga/src/disp/rt_night.v" \
    "fpga/src/disp/rt_zoom_ana.v" \
    "fpga/src/cam/cmos_8_16bit.v" \
    "fpga/src/cam/i2c_com.v" \
    "fpga/src/cam/power_on_delay.v" \
    "fpga/src/cam/reg_config.v" \
    "fpga/src/cam/cam_ddr_writer.v" \
] {
    set abs [file join $ROOT $rel]
    if {![file exists $abs]} {
        puts "WARNING: missing source $rel"
        continue
    }
    if {[catch {add_design $abs -verilog} err]} {
        puts "add_design skipped: $rel ($err)"
    }
}

set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
compile -top_module pango_pcie_dma_top -force_to_run
synthesize -ads -selected_syn_tool_opt 2 -force_to_run
dev_map -force_to_run
pnr -planning_before_place Enable -force_to_run -gplace_times 1 -seed_step 1 -gplace_times 6 -pick_first_timing_convergence_seed FALSE
report_timing
gen_bit_stream -master_configuration_clock_frequency {25M} -force_to_run

# 收集产物
set TASK_DIR [file join $SCRIPT_DIR prj_tasks pnr_1]
set SBIT [file join $TASK_DIR generate_bitstream pango_pcie_dma_top.sbit]
if {[file exists $SBIT]} {
    file copy -force $SBIT [file join $OUT_DIR quad_cam23.sbit]
    puts "=== bitstream: [file join $OUT_DIR quad_cam23.sbit]"
} else {
    puts "WARNING: bitstream not found at $SBIT"
}

set RPT_DIR [file join $OUT_DIR cam23_reports]
file mkdir $RPT_DIR
foreach {src dst} [list \
    [file join $TASK_DIR place_route multiseed_result.csv] multiseed_result.csv \
    [file join $TASK_DIR report_timing pango_pcie_dma_top.rtr] pango_pcie_dma_top.rtr \
    [file join $TASK_DIR device_map pango_pcie_dma_top.dmr] pango_pcie_dma_top.dmr \
] {
    if {[file exists $src]} {
        file copy -force $src [file join $RPT_DIR $dst]
    }
}
puts "=== done: out/quad_cam23.sbit + out/cam23_reports/"
