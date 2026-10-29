# NPU Video Inference Progress

- [x] Step 1: Created `tools/npu_train/infer_videos.py` with CLI parsing, environment guard, coordinate conversion, video annotation, CSV logging, summary.json, and hazard check.
- [x] Step 2: Verified `py_compile` and `--help` (exit code 0).
- [x] Step 3: Verified environment guard exits with code 2 when `wsl_env.sh` is not sourced.
- [x] Step 4: Executed CPU short smoke test (`test_smoke_cpu`, 60 frames) with exit code 0; generated 2 mp4s (960x320, 60 frames), 2 csvs, summary.json, and hazard_check.md.
- [x] Step 5: Verified coordinate transformation round-trip between band image and original image space.
