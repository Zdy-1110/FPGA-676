import sys, os, csv
cur_dir = os.path.abspath("tools/lane_fpga")
sys.path.insert(0, cur_dir)
from model import LaneFPGAModel, load_params

p = load_params()
for seg in ["seg_A_solid", "seg_B_dashed", "seg_C_double_yellow"]:
    fcsv = f"E:/Project/nesai2026/log/lane_fpga/vectors/{seg}/frames.csv"
    rcsv = f"E:/Project/nesai2026/log/lane_fpga/vectors/{seg}/rows.csv"
    with open(fcsv, "r") as f:
        f_rows = list(csv.DictReader(f))
    with open(rcsv, "r") as f:
        r_rows = list(csv.DictReader(f))
    print(f"Segment {seg}: {len(f_rows)} frames, {len(r_rows)} row entries.")
