import os, csv

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
type_map = {"none": 0, "dashed": 1, "solid": 2, "double_yellow": 3}

segments = ["seg_A_solid", "seg_B_dashed", "seg_C_double_yellow", "seg_board", "seg_recover"]

for seg in segments:
    seg_dir = os.path.join(REPO_ROOT, "log", "lane_fpga", "vectors", seg)
    out_dir = os.path.join(REPO_ROOT, "fpga", "sim_lane_thr", "ref", seg)
    os.makedirs(out_dir, exist_ok=True)

    frames_csv = os.path.join(seg_dir, "frames.csv")
    rows_csv = os.path.join(seg_dir, "rows.csv")
    frames_hex = os.path.join(out_dir, "frames_ref.hex")
    rows_hex = os.path.join(out_dir, "rows_ref.hex")

    with open(frames_csv, "r", encoding="utf-8") as f:
        reader = list(csv.DictReader(f))
    with open(frames_hex, "w", encoding="utf-8") as f_out:
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
            f_out.write(" ".join(f"{v:08X}" for v in fields) + "\n")

    with open(rows_csv, "r", encoding="utf-8") as f:
        reader = list(csv.DictReader(f))
    with open(rows_hex, "w", encoding="utf-8") as r_out:
        for r in reader:
            fields = [
                int(r["left_x"]) & 0xFFFF,
                int(r["left_hit"]),
                int(r["left_double"]),
                int(r["right_x"]) & 0xFFFF,
                int(r["right_hit"]),
                int(r["right_double"]),
            ]
            r_out.write(" ".join(f"{v:04X}" for v in fields) + "\n")

    print(f"Generated {seg}: frames={len(reader)} rows={len(reader)}")
