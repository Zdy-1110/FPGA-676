import sys, os
cur_dir = os.path.abspath("tools/lane_fpga")
sys.path.insert(0, cur_dir)
from model import LaneFPGAModel, load_params
import numpy as np

p = load_params()
model = LaneFPGAModel(p)
with open(r"E:\Project\nesai2026\log\lane_fpga\vectors\seg_A_solid\frames.bin", "rb") as f:
    buf = f.read(960*540*2 * 2)

raw1 = np.frombuffer(buf[960*540*2 : 2*960*540*2], dtype=np.uint16).reshape((540, 960))
r5 = (raw1 >> 11) & 0x1F
g6 = (raw1 >> 5) & 0x3F
b5 = raw1 & 0x1F
img = np.dstack([(b5<<3).astype(np.uint8), (g6<<2).astype(np.uint8), (r5<<3).astype(np.uint8)])
r_q, g_q, b_q, rgb565_bin = model._quantize_rgb565(img)
r_q16 = r_q.astype(np.int16)
g_q16 = g_q.astype(np.int16)
b_q16 = b_q.astype(np.int16)
G = (r_q16 + (g_q16 << 1) + b_q16) >> 2
Gy = (r_q16 + g_q16) >> 1
min_rg_all = np.minimum(r_q16, g_q16)

y = 344
d_y = 7
x = 313
print(f"y={y}, x={x}, d_y={d_y}:")
print(f"  center x={x}: G={G[y, x]}, Gy={Gy[y, x]}, rq={r_q16[y, x]}, gq={g_q16[y, x]}, bq={b_q16[y, x]}, min_rg={min_rg_all[y, x]}")
print(f"  left x-d={x-d_y}: G={G[y, x-d_y]}, Gy={Gy[y, x-d_y]}")
print(f"  right x+d={x+d_y}: G={G[y, x+d_y]}, Gy={Gy[y, x+d_y]}")

Rw = int(G[y, x]) - max(int(G[y, x-d_y]), int(G[y, x+d_y]))
Ry = int(Gy[y, x]) - max(int(Gy[y, x-d_y]), int(Gy[y, x+d_y]))
print(f"  Rw={Rw}, Ry={Ry}")
is_w = (Rw >= 18) and (G[y, x] >= 120)
is_y = (r_q16[y, x] >= 130) and (g_q16[y, x] >= 120) and ((b_q16[y, x] + 20) <= min_rg_all[y, x]) and (Ry >= 14)
print(f"  is_white={is_w}, is_yellow={is_y}")
