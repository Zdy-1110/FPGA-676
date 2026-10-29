import sys, os
cur_dir = os.path.abspath("tools/lane_fpga")
sys.path.insert(0, cur_dir)
from model import LaneFPGAModel, load_params
import numpy as np

p = load_params()
model = LaneFPGAModel(p)
with open(r"E:\Project\nesai2026\log\lane_fpga\vectors\seg_A_solid\frames.bin", "rb") as f:
    buf = f.read(960*540*2 * 3)

raw0 = np.frombuffer(buf[:960*540*2], dtype=np.uint16).reshape((540, 960))
raw1 = np.frombuffer(buf[960*540*2 : 2*960*540*2], dtype=np.uint16).reshape((540, 960))
raw2 = np.frombuffer(buf[2*960*540*2 : 3*960*540*2], dtype=np.uint16).reshape((540, 960))

def to_bgr(raw):
    r5 = (raw >> 11) & 0x1F
    g6 = (raw >> 5) & 0x3F
    b5 = raw & 0x1F
    return np.dstack([(b5<<3).astype(np.uint8), (g6<<2).astype(np.uint8), (r5<<3).astype(np.uint8)])

res0 = model.process_frame(to_bgr(raw0))
res1 = model.process_frame(to_bgr(raw1))

print("After Frame 1:")
print("  left track valid:", model.left_state.valid)
print("  left a_smooth:", model.left_state.a_smooth_q16)
print("  left b_smooth:", model.left_state.b_smooth_q4)
print("  predict_x(0):", model.left_state.predict_x(0))

res2 = model.process_frame(to_bgr(raw2))
c260 = res2["row_candidates"][0]
print("Frame 2 y=260:")
print("  runs:", c260["runs"])
print("  left_cand:", c260["left_cand"])
