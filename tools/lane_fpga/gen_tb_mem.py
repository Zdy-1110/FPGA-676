import sys, os, csv

cur_dir = os.path.abspath("tools/lane_fpga")
type_map = {"none": 0, "dashed": 1, "solid": 2, "double_yellow": 3}

for seg in ["seg_A_solid", "seg_B_dashed", "seg_C_double_yellow", "seg_board", "seg_recover"]:

    seg_dir = f"E:/Project/nesai2026/log/lane_fpga/vectors/{seg}"
    out_dir = f"D:/pango_build/4_15_PCIE_DMA/sim/lane/{seg}"
    os.makedirs(out_dir, exist_ok=True)
    
    # Process frames.csv
    with open(f"{seg_dir}/frames.csv", "r") as f:
        reader = list(csv.DictReader(f))
    
    with open(f"{out_dir}/frames_ref.hex", "w") as out_f:
        for r in reader:
            fields = [
                int(r["left_n"]),
                int(r["left_sum_y"]),
                int(r["left_sum_yy"]),
                int(r["left_sum_x"]),
                int(r["left_sum_xy"]),
                int(r["left_sum_xx"]),
                int(r["left_raw_valid"]),
                int(r["left_raw_a_q16"]) & 0xFFFFFFFF,
                int(r["left_raw_b_q4"]) & 0xFFFFFFFF,
                int(r["left_ema_a_q16"]) & 0xFFFFFFFF,
                int(r["left_ema_b_q4"]) & 0xFFFFFFFF,
                int(r["left_track_valid"]),
                int(r["left_lost_cnt"]),
                int(r["left_solid_run"]),
                int(r["left_double_count"]),
                type_map.get(r["left_frame_type"], 0),
                type_map.get(r["left_voted_type"], 0),
                int(r["left_x_bot"]) & 0xFFFF,
                int(r["left_depart"]),
                
                int(r["right_n"]),
                int(r["right_sum_y"]),
                int(r["right_sum_yy"]),
                int(r["right_sum_x"]),
                int(r["right_sum_xy"]),
                int(r["right_sum_xx"]),
                int(r["right_raw_valid"]),
                int(r["right_raw_a_q16"]) & 0xFFFFFFFF,
                int(r["right_raw_b_q4"]) & 0xFFFFFFFF,
                int(r["right_ema_a_q16"]) & 0xFFFFFFFF,
                int(r["right_ema_b_q4"]) & 0xFFFFFFFF,
                int(r["right_track_valid"]),
                int(r["right_lost_cnt"]),
                int(r["right_solid_run"]),
                int(r["right_double_count"]),
                type_map.get(r["right_frame_type"], 0),
                type_map.get(r["right_voted_type"], 0),
                int(r["right_x_bot"]) & 0xFFFF,
                int(r["right_depart"]),
            ]
            hex_str = " ".join(f"{v:08X}" for v in fields)
            out_f.write(hex_str + "\n")
            
    # Process rows.csv
    with open(f"{seg_dir}/rows.csv", "r") as f:
        reader = list(csv.DictReader(f))
    with open(f"{out_dir}/rows_ref.hex", "w") as out_r:
        for r in reader:
            fields = [
                int(r["left_x"]) & 0xFFFF,
                int(r["left_hit"]),
                int(r["left_double"]),
                int(r["right_x"]) & 0xFFFF,
                int(r["right_hit"]),
                int(r["right_double"]),
            ]
            hex_str = " ".join(f"{v:04X}" for v in fields)
            out_r.write(hex_str + "\n")

print("Generated frames_ref.hex and rows_ref.hex for all 3 segments.")
