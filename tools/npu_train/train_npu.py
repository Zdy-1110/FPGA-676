#!/usr/bin/env python3
"""Train YOLOv8n model for RK3568 NPU (road-band 960x320)."""

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import sys
import time
import traceback


def check_env_bool(val: str | None, default: bool = False) -> bool:
    """Parse environment variable as boolean following ultralytics env_bool rules."""
    if val is None:
        return default
    return val.strip().lower() in {"1", "true", "yes", "on", "y", "t"}


def check_environment_guard():
    """Verify environment variables before ultralytics import. Exit 2 on failure."""
    errors = []

    yolo_cfg = os.environ.get("YOLO_CONFIG_DIR", "")
    if not yolo_cfg.rstrip("/\\").endswith(".yolo_cfg_wsl"):
        errors.append(
            f"YOLO_CONFIG_DIR must end with '.yolo_cfg_wsl', current: '{yolo_cfg}'"
        )

    autoinstall_val = os.environ.get("YOLO_AUTOINSTALL")
    if autoinstall_val is None or check_env_bool(autoinstall_val, default=True):
        errors.append(
            f"YOLO_AUTOINSTALL must be false, current: '{autoinstall_val}'"
        )

    offline_val = os.environ.get("YOLO_OFFLINE")
    if offline_val is None or not check_env_bool(offline_val, default=False):
        errors.append(
            f"YOLO_OFFLINE must be true, current: '{offline_val}'"
        )

    if errors:
        sys.stderr.write("Environment Guard Error:\n")
        for err in errors:
            sys.stderr.write(f"  - {err}\n")
        sys.exit(2)


def parse_cache(val: str | None):
    """Parse cache parameter allowing strings ('ram', 'disk') or booleans."""
    if val is None:
        return None
    val_lower = val.strip().lower()
    if val_lower in {"true", "1", "yes"}:
        return True
    if val_lower in {"false", "0", "no"}:
        return False
    return val


def compute_stats_sha256(data_yaml_path: str) -> str | None:
    """Compute SHA-256 of stats.json located next to data.yaml."""
    data_p = Path(data_yaml_path).resolve()
    stats_p = data_p.parent / "stats.json"
    if stats_p.is_file():
        h = hashlib.sha256()
        with open(stats_p, "rb") as f:
            while chunk := f.read(65536):
                h.update(chunk)
        return h.hexdigest()
    return None


def parse_args():
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Train YOLOv8n for RK3568 NPU (road-band 960x320)"
    )
    parser.add_argument(
        "--name", type=str, required=True, help="Run name (required)"
    )
    parser.add_argument(
        "--data",
        type=str,
        default="datasets/npu_v1w/data.yaml",
        help="Path to data.yaml",
    )
    parser.add_argument(
        "--weights",
        type=str,
        default="/mnt/e/Project/Python_Project/yolo/yolov8n.pt",
        help="Pretrained weights path",
    )
    parser.add_argument(
        "--model-yaml",
        type=str,
        default=None,
        help="Path to model yaml config (optional)",
    )
    parser.add_argument(
        "--hyp",
        type=str,
        default="tools/npu_train/hyp_v1.yaml",
        help="Path to hyperparameters yaml",
    )
    parser.add_argument(
        "--epochs", type=int, default=None, help="Override epochs"
    )
    parser.add_argument(
        "--batch", type=int, default=None, help="Override batch size"
    )
    parser.add_argument(
        "--workers", type=int, default=None, help="Override dataloader workers"
    )
    parser.add_argument(
        "--patience", type=int, default=None, help="Override early stopping patience"
    )
    parser.add_argument(
        "--fraction", type=float, default=None, help="Override dataset fraction"
    )
    parser.add_argument(
        "--device",
        type=str,
        default="0",
        help="Device to train on (default '0', use 'cpu' for CPU)",
    )
    parser.add_argument(
        "--cache",
        type=str,
        default=None,
        help="Override cache setting (ram, disk, False, True)",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Resume training from last.pt",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    # Step b: Environment Guard check BEFORE importing ultralytics
    check_environment_guard()

    # Fixed project output directory
    project_dir = Path("/mnt/e/Project/nesai2026/runs/npu_train")
    run_dir = project_dir / args.name

    # Step c: Directory existence and resume check
    if not args.resume:
        if run_dir.exists():
            sys.stderr.write(
                f"Error: Output directory '{run_dir}' already exists and --resume is not set.\n"
            )
            sys.exit(2)
    else:
        last_pt = run_dir / "weights" / "last.pt"
        if not last_pt.is_file():
            sys.stderr.write(
                f"Error: Checkpoint '{last_pt}' does not exist for --resume.\n"
            )
            sys.exit(2)

    try:
        # Import heavy packages only after guards pass
        import torch
        import yaml
        from ultralytics import YOLO

        # Step d: Parameter merging
        train_kwargs = {}
        if not args.resume:
            if not os.path.isfile(args.hyp):
                sys.stderr.write(f"Error: Hyperparameter file '{args.hyp}' not found.\n")
                sys.exit(2)
            with open(args.hyp, "r", encoding="utf-8") as f:
                train_kwargs = yaml.safe_load(f) or {}

            # CLI overrides (non-None values override hyp)
            if args.epochs is not None:
                train_kwargs["epochs"] = args.epochs
            if args.batch is not None:
                train_kwargs["batch"] = args.batch
            if args.workers is not None:
                train_kwargs["workers"] = args.workers
            if args.patience is not None:
                train_kwargs["patience"] = args.patience
            if args.fraction is not None:
                train_kwargs["fraction"] = args.fraction
            parsed_cache = parse_cache(args.cache)
            if parsed_cache is not None:
                train_kwargs["cache"] = parsed_cache

            # Fixed / mandatory arguments
            train_kwargs["data"] = args.data
            train_kwargs["device"] = args.device
            train_kwargs["project"] = str(project_dir)
            train_kwargs["name"] = args.name
            train_kwargs["exist_ok"] = False

        # Prepare run_meta dictionary
        cuda_avail = torch.cuda.is_available()
        if args.device == "cpu":
            dev_name = "CPU"
        elif cuda_avail:
            try:
                dev_idx = int(args.device.split(",")[0]) if args.device.isdigit() else 0
                dev_name = torch.cuda.get_device_name(dev_idx)
            except Exception:
                dev_name = f"CUDA:{args.device}"
        else:
            dev_name = str(args.device)

        start_dt = datetime.now()
        start_time_iso = start_dt.isoformat()
        start_ts = time.time()

        run_meta = {
            "final_kwargs": train_kwargs,
            "hyp_path": str(Path(args.hyp).resolve()) if not args.resume else None,
            "model_yaml": str(Path(args.model_yaml).resolve()) if args.model_yaml and not args.resume else None,
            "stats_json_sha256": compute_stats_sha256(args.data),
            "python_version": platform.python_version(),
            "torch_version": torch.__version__,
            "ultralytics_version": None,  # filled after import
            "torch_cuda_version": torch.version.cuda,
            "cuda_available": cuda_avail,
            "device_name": dev_name,
            "start_time": start_time_iso,
            "end_time": None,
            "duration_seconds": None,
        }
        import ultralytics
        run_meta["ultralytics_version"] = ultralytics.__version__
        if args.resume and (run_dir / "run_meta.json").is_file():
            # Keep the original provenance; record each resume instead of overwriting it
            with open(run_dir / "run_meta.json", "r", encoding="utf-8") as mf:
                prev_meta = json.load(mf)
            prev_meta.setdefault("resumes", []).append(start_time_iso)
            prev_meta.update(end_time=None, duration_seconds=None)
            run_meta = prev_meta

        actual_save_dir = [None]

        def on_pretrain_routine_start(trainer):
            """Record run_meta.json right after ultralytics creates the output directory."""
            sdir = Path(trainer.save_dir)
            actual_save_dir[0] = sdir
            meta_path = sdir / "run_meta.json"
            try:
                with open(meta_path, "w", encoding="utf-8") as mf:
                    json.dump(run_meta, mf, indent=2, default=str)
            except Exception as e:
                sys.stderr.write(f"Warning: Failed to write initial run_meta.json: {e}\n")

        # Step c/d: Model initialization and training
        if args.resume:
            last_pt = run_dir / "weights" / "last.pt"
            ckpt = torch.load(str(last_pt), map_location="cpu", weights_only=False)
            if ckpt.get("optimizer") is None or ckpt.get("epoch", -1) < 0:
                # A finished run has its optimizer stripped; ultralytics would then silently
                # start a fresh training with default cfg (coco8, auto device) instead of failing
                sys.stderr.write(f"Error: '{last_pt}' is a finished run, nothing to resume.\n")
                sys.exit(2)
            train_kwargs["device"] = ckpt.get("train_args", {}).get("device", args.device)  # final val on the run's own device
            model = YOLO(str(last_pt))
            model.add_callback("on_pretrain_routine_start", on_pretrain_routine_start)
            model.train(resume=True)
        else:
            if not os.path.isfile(args.weights):
                sys.stderr.write(f"Error: Weights file '{args.weights}' not found.\n")
                sys.exit(2)
            if args.model_yaml:
                if not os.path.isfile(args.model_yaml):
                    sys.stderr.write(f"Error: Model YAML file '{args.model_yaml}' not found.\n")
                    sys.exit(2)
                model = YOLO(args.model_yaml)
                model.load(args.weights)
            else:
                model = YOLO(args.weights)
            model.add_callback("on_pretrain_routine_start", on_pretrain_routine_start)
            model.train(**train_kwargs)

        end_dt = datetime.now()
        end_ts = time.time()
        duration_sec = round(end_ts - start_ts, 2)
        run_meta["end_time"] = end_dt.isoformat()
        run_meta["duration_seconds"] = duration_sec

        # Update run_meta.json in actual_save_dir or run_dir
        out_save_dir = actual_save_dir[0] or (getattr(model, "trainer", None) and getattr(model.trainer, "save_dir", None)) or run_dir
        out_save_dir = Path(out_save_dir)
        meta_file = out_save_dir / "run_meta.json"
        with open(meta_file, "w", encoding="utf-8") as mf:
            json.dump(run_meta, mf, indent=2, default=str)

        # Step f: Post-training validation with best.pt and per_class.md generation
        best_pt = out_save_dir / "weights" / "best.pt"
        if not best_pt.is_file():
            # Fallback to last.pt if best.pt is absent
            fallback = out_save_dir / "weights" / "last.pt"
            if fallback.is_file():
                best_pt = fallback
            else:
                raise FileNotFoundError(f"Neither best.pt nor last.pt found in {out_save_dir / 'weights'}")

        val_batch = train_kwargs.get("batch", 16) if not args.resume else 16
        val_device = train_kwargs.get("device", args.device)

        val_model = YOLO(str(best_pt))
        metrics = val_model.val(
            data=args.data,
            imgsz=960,
            split="val",
            rect=True,
            batch=val_batch,
            device=val_device,
            plots=False,
            project=str(project_dir),
            name=f"{args.name}_val",
        )

        # Build per-class evaluation table
        # Names map from data.yaml or model
        names_dict = getattr(val_model, "names", None) or getattr(metrics, "names", None)
        if not names_dict:
            with open(args.data, "r", encoding="utf-8") as df:
                names_dict = yaml.safe_load(df).get("names", {})
        if isinstance(names_dict, list):
            names_dict = {i: n for i, n in enumerate(names_dict)}

        num_classes = len(names_dict)
        nt_per_class = getattr(metrics, "nt_per_class", None)

        box_metrics = getattr(metrics, "box", None)
        ap_class_index = []
        p_arr, r_arr, ap50_arr, ap_arr = [], [], [], []
        if box_metrics is not None:
            ap_class_index = list(getattr(box_metrics, "ap_class_index", []))
            p_arr = getattr(box_metrics, "p", [])
            r_arr = getattr(box_metrics, "r", [])
            ap50_arr = getattr(box_metrics, "ap50", [])
            ap_arr = getattr(box_metrics, "ap", [])

        table_lines = [
            "| 类名 | 实例数 | P | R | AP50 | AP50-95 |",
            "| :--- | :---: | :---: | :---: | :---: | :---: |",
        ]

        for i in range(num_classes):
            c_name = names_dict.get(i, str(i))
            inst_count = int(nt_per_class[i]) if (nt_per_class is not None and i < len(nt_per_class)) else 0
            if inst_count == 0:
                table_lines.append(f"| {c_name} | 0 | n/a | n/a | n/a | n/a |")
            else:
                if i in ap_class_index:
                    idx = ap_class_index.index(i)
                    p_val = float(p_arr[idx])
                    r_val = float(r_arr[idx])
                    ap50_val = float(ap50_arr[idx])
                    ap_val = float(ap_arr[idx])
                    table_lines.append(
                        f"| {c_name} | {inst_count} | {p_val:.4f} | {r_val:.4f} | {ap50_val:.4f} | {ap_val:.4f} |"
                    )
                else:
                    table_lines.append(f"| {c_name} | {inst_count} | n/a | n/a | n/a | n/a |")

        per_class_table = "\n".join(table_lines) + "\n"
        per_class_path = out_save_dir / "per_class.md"
        with open(per_class_path, "w", encoding="utf-8", newline="\n") as pf:
            pf.write(per_class_table)

        print("\n=== Per-Class Validation Results ===")
        print(per_class_table)

    except Exception:
        traceback.print_exc()
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
