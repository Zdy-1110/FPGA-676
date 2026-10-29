# 回退：把第 1 段回读的原始内容写回 flash 并校验。
cfg_connect -ip 127.0.0.1 -port 65421
cfg_scan_chain
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -file D:/pango_work/flash_backup/flash_orig_20261018_a.sfc -device_index 0
cfg_jtag_flash_erase -device_index 0
cfg_jtag_flash_program -device_index 0
cfg_jtag_flash_verify -device_index 0
cfg_close
