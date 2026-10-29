#!/bin/sh
# p29_phy_status.sh — 板上运行，只读：RK PCIe3 PHY（P29 用）的时钟门控状态 + PCIE30_PHY_GRF 寄存器（TRM：基地址 0xFDCB8000）。
#   CON3(0x0C) bit15 ref_use_pad(1=U53 外部时钟) bit13 ref_clkdet_en；STATUS0(0x80) bit29 ref_clkdet_result bit27 mplla_state。
#   pclk_pcie30phy 没开就不读 GRF，避免访问被门控的外设挂死总线。不写任何寄存器。
D=/sys/kernel/debug/clk/clk_summary
[ -r $D ] || echo "no clk_summary (debugfs not mounted?)"
echo "== clocks (name enable prepare protect rate)"; grep -iE "pcie30|pcie3x2|pcie20|clk_pcie|pclk_pipe" $D 2>/dev/null | awk '{print $1, $2, $3, $4, $5}'
echo "== dmesg"; dmesg | grep -iE "snps|pcie3-phy|lock failed|3c0800000.pcie: PCIe (Link|Linking)" | tail -6
EN=$(awk '$1=="pclk_pcie30phy"{print $2}' $D 2>/dev/null); echo "pclk_pcie30phy enable_cnt=${EN:-unknown}"
command -v devmem >/dev/null || { echo "no devmem"; exit 0; }
if [ "${EN:-0}" -ge 1 ] 2>/dev/null; then
  for o in 00 04 08 0c 10 14 18 1c 20 24 80 84 88; do echo "GRF+0x$o = $(devmem 0xfdcb80$o 32)"; done
else echo "pclk_pcie30phy off/unknown: GRF reads skipped"; fi
