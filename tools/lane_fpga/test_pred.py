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

print("Left state before process_frame:")
print("  valid:", model.left_state.valid)
print("  a_smooth_q16:", model.left_state.a_smooth_q16)
print("  b_smooth_q4:", model.left_state.b_smooth_q4)
print("  predict_x(55):", model.left_state.predict_x(55))
