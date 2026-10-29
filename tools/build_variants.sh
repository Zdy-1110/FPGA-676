#!/bin/sh
# build_variants.sh <dac> [<dac> ...] — 依次以不同的 CH1 TX_AMP_DAC0 重编译 4_15 x2 工程，产物存到 D:/pango_work/pango_pcie_dma_x2_fs_dac<N>.sbit
# fs = full swing (soft PHY swing_ctl 已固定为 0)。每个版本约 3.5 分钟。
P=/d/pango_build/4_15_PCIE_DMA
X2=$P/ip/PCIe_IP/rtl/hsstlp/ipm2l_pcie_hsstlp_x2_top.v
for d in "$@"; do
  sed -i "s/^localparam CH1_TX_AMP_DAC0 = [0-9]*;/localparam CH1_TX_AMP_DAC0 = $d;/" "$X2"
  grep -n "^localparam CH[01]_TX_AMP_DAC0" "$X2"
  rm -f $P/pnr/prj_tasks/pnr_1/generate_bitstream/pango_pcie_dma_top.sbit
  (cd $P/pnr && "/d/pango_pds/bin/pds_shell.exe" -file build_x2.tcl > build_dac$d.log 2>&1)
  echo "dac$d pds_shell rc=$?"
  grep -E "^E: |failed|Total Real Time" $P/pnr/build_dac$d.log | head -8
  grep -iE "setup.*slack|hold.*slack|WNS|TNS" $P/pnr/build_dac$d.log | tail -4
  if [ -f $P/pnr/prj_tasks/pnr_1/generate_bitstream/pango_pcie_dma_top.sbit ]; then
    cp $P/pnr/prj_tasks/pnr_1/generate_bitstream/pango_pcie_dma_top.sbit /d/pango_work/pango_pcie_dma_x2_fs_dac$d.sbit
    ls -l /d/pango_work/pango_pcie_dma_x2_fs_dac$d.sbit
  else
    echo "dac$d: no sbit"; exit 1
  fi
done
