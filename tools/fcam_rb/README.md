# fcam_rb - FPGA 前摄 DDR 回读测试工具

## 1. 用途
RK3568 用户态工具，通过 `/dev/mem` (BAR1 0xf0204000) 与 `/dev/dma_heap/cma` 分配的物理连续内存，利用 FPGA 片上 DDR 回读通路与 PCIe DMA (MWr) 将 OV5640 前摄写入 DDR slot0 的帧（960×540 RGB565，1,036,800 字节）拉取到 RK3568 主机内存，用于板端前摄抓图、画质验证与回读延迟基准测试。

## 2. 寄存器序列
1. **帧同步与双缓冲判定**：
   - 读 `0x820 FB_STAT` 的 `[31:16]` (`stat_frame_id`)。
   - 每当硬件提交新帧，`stat_frame_id` 递增。
   - 双缓冲基地址：`FB_BASE` (0x804，默认 `0x04000000`)。
   - 奇数帧 (`stat_frame_id & 1`) 在 Buffer 1 (`FB_BASE + 0x00100000` = `0x04100000`)；偶数帧在 Buffer 0 (`FB_BASE` = `0x04000000`)。
2. **分段 DDR -> 片上 RAM 回读**（每段 ≤ 32 KB，512B 对齐）：
   - `0x1A8` = DDR 源地址 (`ddr_addr + seg`)
   - `0x1AC` = 字节数 (`slen`)
   - `0x1B0` = 片上 RAM 偏移（128-bit 字单位，固定设为 `2048`，即 32 KB 偏移处）
   - 读 `old = 0x1DC (rb_done_cnt)`
   - `0x1B4` 写 1 启动回读
   - 轮询 `0x1DC != old`（50 ms 超时）
3. **分块片上 RAM -> 主机 CMA (MWr)**（每块 ≤ 8 KB）：
   - `0x210` = RAM 偏移（16-bit 字单位，`(2048 + (chunk >> 4)) * 8`）
   - `0x200` = 主机 CMA 物理地址低 32 位 (`dst_phys + seg + chunk`)
   - `0x204` = 0（物理地址高 32 位）
   - `0x220` = 1023（传统长度）
   - `0x250` = `clen >> 2`（扩展长度 DW）
   - `0x240` 写 0 触发传输
   - 轮询 `0x230 != 0`（50 ms 超时，读即清零）
4. **清理**：传输完毕写 `0x250 = 0`, `0x210 = 0`。

## 3. 构建与运行命令
- **交叉编译**：
  ```sh
  sh tools/rk_build.sh tools/fcam_rb/fcam_rb tools/fcam_rb/fcam_rb.c
  ```
- **板端运行**：
  ```sh
  ./fcam_rb --bar1 0xf0204000 --count 5 --out /tmp/fcam_%02d.rgb565
  ```

## 4. 像素格式与 PC 端 PNG 转换
- **格式**：显示端 `rt_disp_win_reader_rgb` 的 `RB_SWAP=1`，在 16 位小端字中：
  - `[4:0]` 为 Red (5 bit)
  - `[10:5]` 为 Green (6 bit)
  - `[15:11]` 为 Blue (5 bit)
  即小端内存布局为 BGR565（低字节包含 Red，高字节包含 Blue）。
- **Python 转换**：使用 `rgb565_to_png.py` 将 raw 图像导出为标准 RGB888 PNG：
  ```sh
  python rgb565_to_png.py /tmp/fcam_00.rgb565 /tmp/fcam_00.png
  ```
