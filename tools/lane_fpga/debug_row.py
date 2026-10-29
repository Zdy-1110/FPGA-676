import sys, os
cur_dir = os.path.abspath(os.path.dirname(__file__))
sys.path.insert(0, cur_dir)
site_pkg = os.path.abspath(os.path.join(cur_dir, "..", "..", ".venv_yolo", "Lib", "site-packages"))
if os.path.exists(site_pkg):
    sys.path.insert(0, site_pkg)
import numpy as np
import cv2
from model import LaneFPGAModel, load_params



p = load_params()
model = LaneFPGAModel(p)

with open(r"E:\Project\nesai2026\log\lane_fpga\vectors\seg_A_solid\frames.bin", "rb") as f:
    buf = f.read(960*540*2)

raw = np.frombuffer(buf, dtype=np.uint16).reshape((540, 960))
r5 = (raw >> 11) & 0x1F
g6 = (raw >> 5) & 0x3F
b5 = raw & 0x1F

r_q = (r5 << 3).astype(np.uint8)
g_q = (g6 << 2).astype(np.uint8)
b_q = (b5 << 3).astype(np.uint8)
img_bgr = np.dstack([b_q, g_q, r_q])

res = model.process_frame(img_bgr)

for y in range(260, 265):
    cand = res["row_candidates"][y - 260]
    print(f"y={y}: d_y={cand['d_y']}, w_max={cand['w_max']}, W_y={cand['W_y']}")
    print(f"  runs ({len(cand['runs'])}): {cand['runs']}")
    print(f"  left_cand={cand['left_cand']}, right_cand={cand['right_cand']}, dbl_l={cand['double_left']}, dbl_r={cand['double_right']}")
