#!/bin/bash
# live view, refresh every 30 s (Ctrl+C to stop)
while true; do clear; bash /d/pango_build/4_15_PCIE_DMA/sim/lane_gl/progress.sh; echo; echo "(refresh 30 s, Ctrl+C to stop)"; sleep 30; done
