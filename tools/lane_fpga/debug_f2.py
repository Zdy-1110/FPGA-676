import sys, os
cur_dir = os.path.abspath("tools/lane_fpga")
sys.path.insert(0, cur_dir)
from model import LaneFPGAModel, load_params
import numpy as np

p = load_params()
model = LaneFPGAModel(p)
with open(r"E:\Project\nesai2026\log\lane_fpga\vectors\seg_A_solid\frames.bin", "rb") as f:
    buf = f.read(960*540*2 * 3)

for f_idx in range(3):
    raw = np.frombuffer(buf[f_idx*960*540*2 : (f_idx+1)*960*540*2], dtype=np.uint16).reshape((540, 960))
    r5 = (raw >> 11) & 0x1F
    g6 = (raw >> 5) & 0x3F
    b5 = raw & 0x1F
    img = np.dstack([(b5<<3).astype(np.uint8), (g6<<2).astype(np.uint8), (r5<<3).astype(np.uint8)])
    res = model.process_frame(img)
    cand260 = res["row_candidates"][0]
    print(f"Frame {f_idx} y=260:")
    print("  x_pred_l:", model.left_state.predict_x(0))
    print("  left_cand:", cand260["left_cand"], "right_cand:", cand260["right_cand"])
    print("  runs near 400:", [rx for rx in cand260["runs"] if 390 <= rx <= 415])
