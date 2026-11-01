# 写 cam18 到 FPGA SPI flash（XT25BF128）：生成 sfc → 擦除 → 写入 → 回读（校验用字节比对，cfg_jtag_flash_verify 在本机会因 bin 目录无写权限失败）。
# 执行前必须已安全断链（RK 上 remove EP + Link Disable）。
cfg_gen_sfc -sbit D:/pango_work/quad/out/quad_cam18.sbit -sfc D:/pango_work/quad/out/quad_cam18.sfc
cfg_connect -ip 127.0.0.1 -port 65421
cfg_scan_chain
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -file D:/pango_work/quad/out/quad_cam18.sfc -device_index 0
cfg_jtag_flash_erase -device_index 0
cfg_jtag_flash_program -device_index 0
cfg_jtag_flash_readback -device_index 0 -file D:/pango_work/flash_backup/flash_cam18_readback.sfc
cfg_close
