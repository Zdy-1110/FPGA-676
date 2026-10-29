#!/bin/sh
# build_post1.sh <v> [<v> ...] — 依次以不同的 CH1_POST1_CURSOR_EMPHASIS（lane 1 在 Gen2 -6 dB 请求下的 TX 去加重，0..31，原值 19）
# 重编译 4_15 x2 工程（当前源码含 ltssm_logger），产物存到 D:/pango_work/pango_pcie_dma_x2_post1_<v>.sbit，并生成 prog_x2_post1_<v>.tcl
P=/d/pango_build/4_15_PCIE_DMA
X2=$P/ip/PCIe_IP/rtl/hsstlp/ipm2l_pcie_hsstlp_x2_top.v
for v in "$@"; do
  sed -i "s/^localparam CH1_POST1_CURSOR_EMPHASIS = [0-9]*;/localparam CH1_POST1_CURSOR_EMPHASIS = $v;/" "$X2"
  grep -n "^localparam CH[01]_POST1_CURSOR_EMPHASIS" "$X2"
  rm -f $P/pnr/prj_tasks/pnr_1/generate_bitstream/pango_pcie_dma_top.sbit
  (cd $P/pnr && "/d/pango_pds/bin/pds_shell.exe" -file build_x2.tcl > build_post1_$v.log 2>&1)
  echo "post1=$v pds_shell rc=$?"
  grep -E "^E: |failed" $P/pnr/build_post1_$v.log | head -5
  S=$P/pnr/prj_tasks/pnr_1/generate_bitstream/pango_pcie_dma_top.sbit
  [ -f $S ] || { echo "post1=$v: no sbit"; exit 1; }
  cp $S /d/pango_work/pango_pcie_dma_x2_post1_$v.sbit
  sed "s#pango_pcie_dma_x2_ltssmlog.sbit#pango_pcie_dma_x2_post1_$v.sbit#" /d/pango_work/prog_x2_ltssmlog.tcl > /d/pango_work/prog_x2_post1_$v.tcl
  ls -l /d/pango_work/pango_pcie_dma_x2_post1_$v.sbit
done
