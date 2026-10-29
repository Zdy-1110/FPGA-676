# NPU YOLOv8n Training Progress

- [x] Step 1: Created `tools/npu_train/hyp_v1.yaml` and verified valid ultralytics hyperparameters.
- [x] Step 2: Implement `tools/npu_train/train_npu.py` with environment guards, argument parsing, run_meta recording, training execution, and per-class evaluation.
- [x] Step 3: Verify py_compile and --help.
- [x] Step 4: Verify environment guard exit code 2.
- [x] Step 5: Run CPU smoke test and verify artifacts (`best.pt`, `run_meta.json`, `per_class.md`).
- [x] Step 6: Verify no download/install in smoke log.
