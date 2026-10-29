#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# Select compiler
if [ -f "/mnt/d/tools/zig-x86_64-windows-0.14.1/zig.exe" ]; then
    CC="/mnt/d/tools/zig-x86_64-windows-0.14.1/zig.exe cc -target x86_64-linux-gnu"
elif command -v gcc >/dev/null 2>&1; then
    CC="gcc"
elif command -v cc >/dev/null 2>&1; then
    CC="cc"
else
    echo "ERROR: No suitable C compiler found"
    exit 1
fi

echo "=== [1/6] Compiling test_units and test_post with -std=c99 -Wall -Wextra ==="
$CC -std=c99 -Wall -Wextra -O2 test_units.c ../npu_post.c -o test_units -lm
$CC -std=c99 -Wall -Wextra -O2 test_post.c ../npu_post.c -o test_post -lm
echo "Compilation OK: 0 warnings."

echo "=== [2/6] Running unit tests ==="
./test_units

echo "=== [3/6] Running Test: FP32 + pr_split ==="
./test_post data fp32 pr_split data/pred_onnx_pr_split.json
python3 compare.py data/ref_onnx_pr_split.json data/pred_onnx_pr_split.json

echo "=== [4/6] Running Test: FP32 + agnostic ==="
./test_post data fp32 agnostic data/pred_onnx_agnostic.json
python3 compare.py data/ref_onnx_agnostic.json data/pred_onnx_agnostic.json

echo "=== [5/6] Running Test: INT8 + pr_split ==="
./test_post data int8 pr_split data/pred_rknn_pr_split.json
python3 compare.py data/ref_rknn_pr_split.json data/pred_rknn_pr_split.json

echo "=== [6/6] Running Test: INT8 + agnostic ==="
./test_post data int8 agnostic data/pred_rknn_agnostic.json
python3 compare.py data/ref_rknn_agnostic.json data/pred_rknn_agnostic.json

echo "=========================================="
echo "ALL TESTS PASSED! (Unit tests + 4 comparison groups)"
echo "=========================================="
