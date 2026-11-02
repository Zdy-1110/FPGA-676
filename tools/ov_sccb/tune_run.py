#!/usr/bin/env python3
"""
tools/ov_sccb/tune_run.py - Automated OV5640 register tuning and image quality evaluation.
"""

import sys
import os
import tempfile
import glob
import json
import time
import datetime
import argparse
import csv
from pathlib import Path

import numpy as np
from PIL import Image

# Insert tools/fcam_rb to sys.path to import analyze_fcam
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools" / "fcam_rb"))
import analyze_fcam

DEFAULT_OUTDIR = os.path.join(tempfile.gettempdir(), "tune")
DEFAULT_HOST = "192.168.3.51"

def parse_args():
    parser = argparse.ArgumentParser(description="Automate OV5640 tuning and quality evaluation")
    parser.add_argument("--name", help="Name of the tuning experiment")
    parser.add_argument("--tune", help="Path to register tuning file")
    parser.add_argument("--regs", help="Comma-separated registers, e.g. '0x5183 0x94,0x3a19 0x7c'")
    parser.add_argument("--settle", type=float, default=3.0, help="Settle time in seconds for AE/AWB (default: 3)")
    parser.add_argument("--frames", type=int, default=30, help="Number of frames to capture (default: 30)")
    parser.add_argument("--roi", help="White reference ROI: x0,y0,x1,y1")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Target board IP (default: {DEFAULT_HOST})")
    parser.add_argument("--outdir", default=DEFAULT_OUTDIR, help=f"Output directory (default: {DEFAULT_OUTDIR})")
    parser.add_argument("--summary", action="store_true", help="Print summary table and exit")
    parser.add_argument("--offline", help="Run offline analysis on local .rgb565 directory without SSH")
    args = parser.parse_args()

    if args.summary:
        return args

    if not args.name:
        parser.error("--name is required unless --summary is specified")

    if args.tune and args.regs:
        parser.error("Cannot specify both --tune and --regs")

    return args

def print_summary_table(summary_path):
    if not os.path.isfile(summary_path):
        print(f"Summary file not found: {summary_path}")
        return 0

    with open(summary_path, "r", encoding="utf-8") as f:
        reader = csv.reader(f)
        rows = [row for row in reader if row]

    if not rows:
        print(f"Summary file is empty: {summary_path}")
        return 0

    num_cols = len(rows[0])
    col_widths = [0] * num_cols
    for row in rows:
        for i in range(num_cols):
            val = row[i] if i < len(row) else ""
            if len(val) > col_widths[i]:
                col_widths[i] = len(val)

    # Format header
    header = rows[0]
    hdr_line = " | ".join(f"{header[i]:<{col_widths[i]}}" for i in range(num_cols))
    sep_line = "-+-".join("-" * col_widths[i] for i in range(num_cols))

    print(f"+-{sep_line}-+")
    print(f"| {hdr_line} |")
    print(f"+={sep_line}=+")

    for row in rows[1:]:
        data_line = " | ".join(f"{(row[i] if i < len(row) else ''):<{col_widths[i]}}" for i in range(num_cols))
        print(f"| {data_line} |")
    print(f"+-{sep_line}-+")
    return 0

def parse_registers(args):
    reg_list = []
    tune_content = ""
    if args.tune:
        if not os.path.isfile(args.tune):
            print(f"Error: tuning file '{args.tune}' not found", file=sys.stderr)
            sys.exit(1)
        with open(args.tune, "r", encoding="utf-8") as f:
            tune_content = f.read()
        for line in tune_content.splitlines():
            clean = line.split("#")[0].strip()
            if clean:
                reg_list.append(clean)
    elif args.regs:
        parts = [p.strip() for p in args.regs.split(",") if p.strip()]
        for p in parts:
            reg_list.append(p)
        tune_content = "\n".join(reg_list) + "\n"
    return reg_list, tune_content

def append_to_summary(summary_path, row_data):
    headers = [
        "name", "time", "registers",
        "mean_R", "mean_G", "mean_B",
        "white_RG", "white_BG",
        "mean_Y", "flicker_Y",
        "noise_Y", "noise_R", "noise_G", "noise_B",
        "row_noise", "dark_row_noise", "dark_pixel_pct"
    ]
    file_exists = os.path.isfile(summary_path) and os.path.getsize(summary_path) > 0

    os.makedirs(os.path.dirname(os.path.abspath(summary_path)), exist_ok=True)
    with open(summary_path, "a", newline="\n", encoding="utf-8") as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(headers)
        writer.writerow(row_data)

def export_frame0_png(R0, G0, B0, out_path):
    r0 = np.clip(np.round(R0), 0, 255).astype(np.uint8)
    g0 = np.clip(np.round(G0), 0, 255).astype(np.uint8)
    b0 = np.clip(np.round(B0), 0, 255).astype(np.uint8)
    rgb0 = np.stack([r0, g0, b0], axis=-1)
    img = Image.fromarray(rgb0, "RGB")
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    img.save(out_path)

def main():
    args = parse_args()
    summary_path = os.path.join(args.outdir, "summary.csv")

    if args.summary:
        return print_summary_table(summary_path)

    run_dir = os.path.join(args.outdir, args.name)
    os.makedirs(run_dir, exist_ok=True)

    reg_list, tune_content = parse_registers(args)
    ov_sccb_out = ""
    ov_sccb_rc = 0

    if args.offline:
        # Offline mode: skip SSH, analyze local files directly
        if not os.path.isdir(args.offline):
            print(f"Error: offline directory '{args.offline}' not found", file=sys.stderr)
            sys.exit(1)
        pat = os.path.join(args.offline, "*.rgb565")
        matched = sorted(glob.glob(pat))
        if not matched:
            print(f"Error: no .rgb565 files found in '{args.offline}'", file=sys.stderr)
            sys.exit(1)
        files, R, G, B = analyze_fcam.load_frames(matched)
        ov_sccb_out = "offline (skipped)"
        ov_sccb_rc = 0
    else:
        # Online mode: SSH to target board
        import paramiko

        user = os.environ.get("RK_USER", "root")
        passwd = os.environ.get("RK_PASS", "root")

        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(
            args.host,
            username=user,
            password=passwd,
            timeout=8,
            banner_timeout=15,
            allow_agent=False,
            look_for_keys=False
        )
        sftp = client.open_sftp()

        # Ensure /tmp/fcam_rb exists
        try:
            sftp.stat("/tmp/fcam_rb")
        except IOError:
            local_bin = REPO_ROOT / "tools" / "fcam_rb" / "fcam_rb"
            if not local_bin.is_file():
                print(f"Error: local binary {local_bin} not found", file=sys.stderr)
                sys.exit(1)
            sftp.put(str(local_bin), "/tmp/fcam_rb")
            client.exec_command("chmod +x /tmp/fcam_rb")

        # Write registers if requested
        if tune_content:
            remote_tune = f"/tmp/tune_{args.name}.txt"
            with sftp.file(remote_tune, "w") as rf:
                rf.write(tune_content)
            cmd = f"sh /userdata/quad/ov_sccb.sh -f {remote_tune}"
            _, stdout, stderr = client.exec_command(cmd, timeout=60)
            out_str = stdout.read().decode("utf-8", "replace")
            err_str = stderr.read().decode("utf-8", "replace")
            ov_sccb_rc = stdout.channel.recv_exit_status()
            ov_sccb_out = (out_str + "\n" + err_str).strip()
            if ov_sccb_rc != 0:
                print(f"Error: ov_sccb.sh failed with rc={ov_sccb_rc}:\n{ov_sccb_out}", file=sys.stderr)
                sftp.close()
                client.close()
                sys.exit(ov_sccb_rc)

        # Settle wait
        if args.settle > 0:
            time.sleep(args.settle)

        # Capture frames on board
        cmd_cap = f"rm -rf /tmp/fc && mkdir -p /tmp/fc && /tmp/fcam_rb --bar1 0xf0204000 --count {args.frames} --out /tmp/fc/fc_%02d.rgb565"
        _, stdout, stderr = client.exec_command(cmd_cap, timeout=120)
        rc_cap = stdout.channel.recv_exit_status()
        if rc_cap != 0:
            err_msg = stderr.read().decode("utf-8", "replace")
            print(f"Error: fcam_rb capture failed with rc={rc_cap}:\n{err_msg}", file=sys.stderr)
            sftp.close()
            client.close()
            sys.exit(rc_cap)

        # SFTP pull frames
        remote_files = sorted(sftp.listdir("/tmp/fc"))
        local_files = []
        for fn in remote_files:
            if fn.endswith(".rgb565"):
                rem_path = f"/tmp/fc/{fn}"
                loc_path = os.path.join(run_dir, fn)
                sftp.get(rem_path, loc_path)
                local_files.append(loc_path)

        sftp.close()
        client.close()

        files, R, G, B = analyze_fcam.load_frames(local_files)

    # Compute metrics
    metrics = analyze_fcam.compute_metrics(R, G, B, roi=args.roi)
    analyze_fcam.print_metrics(metrics)

    # Export frame0.png
    frame0_path = os.path.join(run_dir, "frame0.png")
    export_frame0_png(R[0], G[0], B[0], frame0_path)
    print(f"Saved first frame PNG to {frame0_path}")

    # Write result.json
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    result_data = {
        "name": args.name,
        "timestamp": now_str,
        "registers": reg_list,
        "ov_sccb_rc": ov_sccb_rc,
        "ov_sccb_output": ov_sccb_out,
        "metrics": metrics
    }
    result_json_path = os.path.join(run_dir, "result.json")
    with open(result_json_path, "w", encoding="utf-8") as jf:
        json.dump(result_data, jf, indent=2, ensure_ascii=False)
    print(f"Saved run result to {result_json_path}")

    # Append to summary.csv
    regs_str = ";".join(reg_list) if reg_list else "-"
    m_r, m_g, m_b = metrics["full_mean_rgb"]
    w_rg = metrics["white_area"]["r_g"]
    w_bg = metrics["white_area"]["b_g"]
    m_y = metrics["full_mean_y"]
    flicker = metrics["flicker_y_std"]
    n_y = metrics["pixel_temporal_noise"]["y"]
    n_r = metrics["pixel_temporal_noise"]["r"]
    n_g = metrics["pixel_temporal_noise"]["g"]
    n_b = metrics["pixel_temporal_noise"]["b"]
    row_n = metrics["row_noise"]["full_width_std"]
    dark_row_n = metrics["dark_area"]["row_noise_std"]
    dark_pct = metrics["dark_area"]["pixel_count"] / (metrics["width"] * metrics["height"]) * 100.0

    summary_row = [
        args.name,
        now_str,
        regs_str,
        f"{m_r:.2f}",
        f"{m_g:.2f}",
        f"{m_b:.2f}",
        f"{w_rg:.3f}",
        f"{w_bg:.3f}",
        f"{m_y:.2f}",
        f"{flicker:.4f}",
        f"{n_y:.3f}",
        f"{n_r:.3f}",
        f"{n_g:.3f}",
        f"{n_b:.3f}",
        f"{row_n:.3f}",
        f"{dark_row_n:.3f}",
        f"{dark_pct:.1f}%"
    ]
    append_to_summary(summary_path, summary_row)
    print(f"Appended summary to {summary_path}")
    return 0

if __name__ == "__main__":
    sys.exit(main() or 0)
