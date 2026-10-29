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
res = model.process_frame(img)

y = 315
y_roi = y - 260
cand = res["row_candidates"][y_roi]
print(f"y={y} (y_roi={y_roi}):")
print("  d_y:", cand["d_y"], "W_y:", cand["W_y"], "w_max:", cand["w_max"])
print("  x_pred_l:", model.left_state.predict_x(y_roi))
print("  runs:", cand["runs"])
print("  left_cand:", cand["left_cand"])
