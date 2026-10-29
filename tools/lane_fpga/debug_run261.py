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

y = 261
d_y = 3
w = 960

row_G = G[y]
row_Gy = Gy[y]
cG = row_G[d_y : w - d_y]
lG = row_G[0 : w - 2 * d_y]
rG = row_G[2 * d_y : w]
R_w = cG - np.maximum(lG, rG)

cGy = row_Gy[d_y : w - d_y]
lGy = row_Gy[0 : w - 2 * d_y]
rGy = row_Gy[2 * d_y : w]
R_y = cGy - np.maximum(lGy, rGy)

crq = r_q16[y, d_y : w - d_y]
cgq = g_q16[y, d_y : w - d_y]
cbq = b_q16[y, d_y : w - d_y]
min_rg = min_rg_all[y, d_y : w - d_y]

is_white = (R_w >= 18) & (cG >= 120)
is_yellow = (crq >= 130) & (cgq >= 120) & ((cbq + 20) <= min_rg) & (R_y >= 14)
is_lane = is_white | is_yellow

n_p = len(is_lane)
trans_up = np.where((is_lane[1:]) & (~is_lane[:-1]))[0] + 1
starts = np.r_[0, trans_up] if is_lane[0] else trans_up
trans_dn = np.where((~is_lane[1:]) & (is_lane[:-1]))[0] + 1
ends = np.r_[trans_dn, n_p] if is_lane[-1] else trans_dn

for s, e in zip(starts, ends):
    c = d_y + (s + e - 1) // 2
    if 390 <= c <= 405:
        print(f"Python run: s={s} (x={s+d_y}), e={e} (x={e+d_y}), len={e-s}, center={c}")
        print("  pixels in is_lane[s-1:e+1]:", is_lane[max(0, s-2):e+2].astype(int))
