# 第 2 段（写 flash）：擦除 → 写入 osd1c.sfc → 校验。只在备份确认无误后执行。
cfg_connect -ip 127.0.0.1 -port 65421
cfg_scan_chain
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -file D:/pango_work/pango_pcie_dma_x2_osd1c.sfc -device_index 0
cfg_jtag_flash_erase -device_index 0
cfg_jtag_flash_program -device_index 0
cfg_jtag_flash_verify -device_index 0
cfg_close
