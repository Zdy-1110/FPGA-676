# 第 1 段（只读）：识别外部 flash 并回读两次做备份。执行前必须已安全断链。
# 回读长度取自所指定文件的大小，所以先指定 readsize_16m.sfc（osd1c.sbit 补 0xFF 到 16 MB，只用来定长度，不写入）。
cfg_connect -ip 127.0.0.1 -port 65421
cfg_scan_chain
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -file D:/pango_work/flash_backup/readsize_16m.sfc -device_index 0
cfg_jtag_flash_readback -device_index 0 -file D:/pango_work/flash_backup/flash_orig_20261018_a.sfc
cfg_jtag_flash_readback -device_index 0 -file D:/pango_work/flash_backup/flash_orig_20261018_b.sfc
cfg_close
