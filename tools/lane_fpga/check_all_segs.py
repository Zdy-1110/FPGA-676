import csv

for seg in ["seg_A_solid", "seg_B_dashed", "seg_C_double_yellow"]:
    path = f"E:/Project/nesai2026/log/lane_fpga/vectors/{seg}/frames.csv"
    with open(path, "r") as f:
        reader = list(csv.DictReader(f))
        print(f"{seg}: {len(reader)} frames")
