import sys, os
cur_dir = os.path.abspath("tools/lane_fpga")
sys.path.insert(0, cur_dir)
from model import LaneFPGAModel, load_params
import numpy as np

p = load_params()
model = LaneFPGAModel(p)
with open(r"E:\Project\nesai2026\log\lane_fpga\vectors\seg_A_solid\frames.bin", "rb") as f:
    buf = f.read(960*540*2 * 2)

raw0 = np.frombuffer(buf[:960*540*2], dtype=np.uint16).reshape((540, 960))
raw1 = np.frombuffer(buf[960*540*2 : 2*960*540*2], dtype=np.uint16).reshape((540, 960))

def to_bgr(raw):
    r5 = (raw >> 11) & 0x1F
    g6 = (raw >> 5) & 0x3F
    b5 = raw & 0x1F
    return np.dstack([(b5<<3).astype(np.uint8), (g6<<2).astype(np.uint8), (r5<<3).astype(np.uint8)])

res0 = model.process_frame(to_bgr(raw0))
res1 = model.process_frame(to_bgr(raw1))

y = 344
y_roi = y - 260
c344 = res1["row_candidates"][y_roi]
print("Python Frame 1 y=344:")
print("  d_y:", c344["d_y"], "W_y:", c344["W_y"], "w_max:", c344["w_max"])
print("  runs:", c344["runs"])
print("  left_cand:", c344["left_cand"])

# Check around 313
print("Runs around 313 in Python:")
print([r for r in c344["runs"] if 300 <= r <= 330])
