import sys, os
cur_dir = os.path.abspath("tools/lane_fpga")
sys.path.insert(0, cur_dir)
from model import LaneFPGAModel, load_params
import numpy as np

p = load_params()
model = LaneFPGAModel(p)
with open(r"E:\Project\nesai2026\log\lane_fpga\vectors\seg_A_solid\frames.bin", "rb") as f:
    buf = f.read(960*540*2)

raw = np.frombuffer(buf, dtype=np.uint16).reshape((540, 960))
r5 = (raw >> 11) & 0x1F
g6 = (raw >> 5) & 0x3F
b5 = raw & 0x1F
img = np.dstack([(b5<<3).astype(np.uint8), (g6<<2).astype(np.uint8), (r5<<3).astype(np.uint8)])

r_q, g_q, b_q, rgb565_bin = model._quantize_rgb565(img)
r_q16 = r_q.astype(np.int16)
g_q16 = g_q.astype(np.int16)
b_q16 = b_q.astype(np.int16)
G = (r_q16 + (g_q16 << 1) + b_q16) >> 2
Gy = (r_q16 + g_q16) >> 1
min_rg_all = np.minimum(r_q16, g_q16)

y = 315
y_roi = y - 260
d_y = round(3 * 240 + y_roi * 11) // 240
print(f"y={y}: d_y={d_y}")

row_G = G[y]
row_Gy = Gy[y]
cG = row_G[d_y : 960 - d_y]
lG = row_G[0 : 960 - 2 * d_y]
rG = row_G[2 * d_y : 960]
R_w = cG - np.maximum(lG, rG)

cGy = row_Gy[d_y : 960 - d_y]
lGy = row_Gy[0 : 960 - 2 * d_y]
rGy = row_Gy[2 * d_y : 960]
R_y = cGy - np.maximum(lGy, rGy)

crq = r_q16[y, d_y : 960 - d_y]
cgq = g_q16[y, d_y : 960 - d_y]
cbq = b_q16[y, d_y : 960 - d_y]
min_rg = min_rg_all[y, d_y : 960 - d_y]

is_white = (R_w >= 18) & (cG >= 120)
is_yellow = (crq >= 130) & (cgq >= 120) & ((cbq + 20) <= min_rg) & (R_y >= 14)
is_lane = is_white | is_yellow

for x in range(350, 360):
    i = x - d_y
    print(f"x={x}: cG={row_G[x]}, lG={row_G[x-d_y]}, rG={row_G[x+d_y]}, Rw={R_w[i]}, is_white={is_white[i]}, is_yellow={is_yellow[i]}")
