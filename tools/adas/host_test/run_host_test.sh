#!/usr/bin/env bash
set -e

# Detect environment and path prefix
if [ -d "/mnt/e/Project/nesai2026" ]; then
    PROJECT_ROOT="/mnt/e/Project/nesai2026"
    WIN_ROOT="E:/Project/nesai2026"
    FFMPEG="/mnt/d/Program Files/FormatFactory/ffmpeg.exe"
    BIN="${PROJECT_ROOT}/tools/adas/host_test/tl_host_main"
else
    PROJECT_ROOT="E:/Project/nesai2026"
    WIN_ROOT="E:/Project/nesai2026"
    FFMPEG="D:/Program Files/FormatFactory/ffmpeg.exe"
    BIN="${PROJECT_ROOT}/tools/adas/host_test/tl_host_main.exe"
fi

ALL_VIDEOS=("112454" "112507" "112739" "113343" "113421" "113452" "113539")
USE_REF=1
OUT_SUB="out"
CUSTOM_VIDEOS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-ref)
            USE_REF=0
            OUT_SUB="out_no_ref"
            shift
            ;;
        --with-ref)
            USE_REF=1
            OUT_SUB="out"
            shift
            ;;
        --out-dir)
            OUT_SUB="$2"
            shift 2
            ;;
        *)
            CUSTOM_VIDEOS+=("$1")
            shift
            ;;
    esac
done

if [ ${#CUSTOM_VIDEOS[@]} -gt 0 ]; then
    VIDEOS=("${CUSTOM_VIDEOS[@]}")
else
    VIDEOS=("${ALL_VIDEOS[@]}")
fi

OUT_DIR="${PROJECT_ROOT}/tools/adas/host_test/${OUT_SUB}"
REF_DIR="${PROJECT_ROOT}/video_review/ref_runs/E_r45"

echo "=== Running ADAS TL Host Test ==="
echo "Mode: $( [ $USE_REF -eq 1 ] && echo 'WITH --ref (shared ego_motion)' || echo 'WITHOUT --ref (independent, ego=moving)' )"
echo "Videos: ${VIDEOS[*]}"
echo "Binary: ${BIN}"
echo "FFmpeg: ${FFMPEG}"
echo "Output: ${OUT_DIR}"

mkdir -p "${OUT_DIR}"

TOTAL_START=$(date +%s)

for vid in "${VIDEOS[@]}"; do
    WIN_VIDEO_FILE="${WIN_ROOT}/video_review/src/video_20260929_${vid}.mp4"
    REF_CSV="${REF_DIR}/${vid}/states.csv"
    VID_OUT_DIR="${OUT_DIR}/${vid}"
    OUT_CSV="${VID_OUT_DIR}/states.csv"

    mkdir -p "${VID_OUT_DIR}"

    echo -n "Processing ${vid}... "
    T0=$(date +%s)

    REF_ARG=()
    if [ $USE_REF -eq 1 ]; then
        REF_ARG=(--ref "${REF_CSV}")
    fi

    # Run ffmpeg piped to tl_host_main
    "${FFMPEG}" -v error -i "${WIN_VIDEO_FILE}" -f rawvideo -pix_fmt bgr24 - | \
        "${BIN}" --w 1920 --h 1080 --step 3 --fps 30 "${REF_ARG[@]}" --out "${OUT_CSV}"
    EC=$?

    T1=$(date +%s)
    DUR=$((T1 - T0))

    LINES=$(wc -l < "${OUT_CSV}")
    echo "Done in ${DUR}s (exit_code=${EC}, lines=${LINES})"
done

TOTAL_END=$(date +%s)
TOTAL_DUR=$((TOTAL_END - TOTAL_START))
echo "=== Completed in ${TOTAL_DUR}s ==="
