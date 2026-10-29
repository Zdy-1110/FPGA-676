#!/bin/bash
# cam10f gate-level progress: seg_recover, 40 frames
D=/d/pango_build/4_15_PCIE_DMA/sim/lane_gl
L=$D/gl_recover40.log
C=$D/gl_recover40_console.log
ST=$D/.progress_state
S=40

[ -f "$L" ] || { echo "not started yet"; exit 0; }

now=$(date +%s)
start=$(stat -c %Y "$C" 2>/dev/null || echo $now)
done_n=$(grep -c '^# \[FRAME' "$L" 2>/dev/null); done_n=${done_n:-0}
mis=$(grep -c 'MISMATCH' "$L" 2>/dev/null); mis=${mis:-0}
lastmod=$(stat -c %Y "$L" 2>/dev/null || echo $now)

rate=0
if [ -f "$ST" ]; then
    read pt pc < "$ST"
    if [ "$done_n" -gt "$pc" ] && [ "$now" -gt "$pt" ]; then
        rate=$(awk -v dt=$((now-pt)) -v dc=$((done_n-pc)) 'BEGIN{printf "%.1f", dt/dc}')
    fi
fi
echo "$now $done_n" > "$ST"

avg=0
[ "$done_n" -gt 0 ] && avg=$(awk -v e=$((now-start)) -v n=$done_n 'BEGIN{printf "%.0f", e/n}')

echo "====== cam10f gate-level seg_recover: $done_n / $S frames ======"
awk -v n=$done_n -v s=$S 'BEGIN{printf "  progress %5.1f%%\n", 100*n/s}'
awk -v e=$((now-start)) 'BEGIN{printf "  elapsed  %d min (%d h %02d m)\n", e/60, e/3600, (e%3600)/60}'
[ "$done_n" -gt 0 ] && awk -v a=$avg 'BEGIN{printf "  average  %.1f min/frame (all frames so far)\n", a/60}'
[ "$rate" -gt 0 ] 2>/dev/null && awk -v r=$rate 'BEGIN{printf "  current  %.1f min/frame (since last check)\n", r/60}'
if [ "$done_n" -gt 0 ] && [ "$done_n" -lt "$S" ]; then
    r=$avg; [ "$rate" -gt 0 ] 2>/dev/null && r=$rate
    eta=$(( now + (S-done_n) * r ))
    echo "  ETA      $(date -d @$eta +%H:%M)  (this computer's clock)"
fi
if [ $((now-lastmod)) -lt 120 ]; then st="printing"; else st="quiet $((now-lastmod)) s"; fi
tasklist 2>/dev/null | grep -qi vsim && echo "  vsim     RUNNING ($st)" || echo "  vsim     not running"
echo "  mismatch $mis"
echo "--- last frames ---"
grep '^# \[FRAME' "$L" | tail -n 3 | cut -c1-150
