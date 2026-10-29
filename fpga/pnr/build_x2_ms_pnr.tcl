open_project D:/pango_build/4_15_PCIE_DMA/pnr/pg2l_pcie_dma.pds
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676
pnr -planning_before_place Enable -force_to_run -gplace_times 4 -seed_step 1 -pick_first_timing_convergence_seed TRUE
report_timing
gen_bit_stream -master_configuration_clock_frequency {25M} -force_to_run
