#!/bin/sh
# tools/ov_sccb/test/run_tests.sh
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OV_SCCB="$ROOT_DIR/tools/ov_sccb/ov_sccb.sh"
MOCK_DEVMEM="$ROOT_DIR/tools/ov_sccb/mock_devmem.sh"
export DEVMEM="$MOCK_DEVMEM"

STATE_FILE="/tmp/mock_state_test.txt"
export MOCK_STATE_FILE="$STATE_FILE"

get_done_cnt() {
    if [ -f "$STATE_FILE" ]; then
        read -r _ done_cnt _ < "$STATE_FILE"
        echo "$done_cnt"
    else
        echo "0"
    fi
}

run_case() {
    name="$1"
    expected_rc="$2"
    shift 2

    # Reset mock state
    def_ver="${MOCK_VER:-0x20261106}"
    echo "$def_ver 0 0 0 0 0 0" > "$STATE_FILE"
    done_before=$(get_done_cnt)

    output=$(sh "$OV_SCCB" "$@" 2>&1)
    actual_rc=$?

    done_after=$(get_done_cnt)

    if [ "$actual_rc" -eq "$expected_rc" ]; then
        status="PASS"
    else
        status="FAIL"
    fi
    printf "%-26s | exp: %d act: %d | done: %s -> %s | %s\n" "$name" "$expected_rc" "$actual_rc" "$done_before" "$done_after" "$status"
    if [ "$status" = "FAIL" ]; then
        echo "  [output] $output"
        FAIL_CNT=$((FAIL_CNT + 1))
    fi
}

FAIL_CNT=0

echo "==================== ov_sccb.sh Test Suite ===================="

# 1. Base 4 cases
unset MOCK_VER MOCK_NACK_REG MOCK_FAIL_READ
run_case "normal_file" 0 -f "$SCRIPT_DIR/test_tune.txt"

export MOCK_VER="0x20261105"
run_case "version_too_low" 4 -f "$SCRIPT_DIR/test_tune.txt"
unset MOCK_VER

run_case "bad_syntax_file" 1 -f "$SCRIPT_DIR/bad_syntax.txt"

export MOCK_NACK_REG="0x3400"
run_case "nack_file" 3 -f "$SCRIPT_DIR/test_tune.txt"
unset MOCK_NACK_REG

# 2. Strict syntax check cases (each tested as temp file)
# sleep_ms 5ms
echo "sleep_ms 5ms" > /tmp/tc_sleep_5ms.txt
run_case "sleep_ms_5ms" 1 -f /tmp/tc_sleep_5ms.txt

# sleep_ms 1+1
echo "sleep_ms 1+1" > /tmp/tc_sleep_expr.txt
run_case "sleep_ms_1+1" 1 -f /tmp/tc_sleep_expr.txt

# 0x3406 xyz
echo "0x3406 xyz" > /tmp/tc_val_xyz.txt
run_case "val_xyz" 1 -f /tmp/tc_val_xyz.txt

# 0x3406 (missing field)
echo "0x3406" > /tmp/tc_missing_val.txt
run_case "missing_val" 1 -f /tmp/tc_missing_val.txt

# 0x3406 0x01 0x02 (extra field)
echo "0x3406 0x01 0x02" > /tmp/tc_extra_field.txt
run_case "extra_field" 1 -f /tmp/tc_extra_field.txt

# 0x13406 0x01 (address > 4 hex digits)
echo "0x13406 0x01" > /tmp/tc_addr_5hex.txt
run_case "addr_over_4hex" 1 -f /tmp/tc_addr_5hex.txt

# 0x3406 0x100 (val > 2 hex digits)
echo "0x3406 0x100" > /tmp/tc_val_3hex.txt
run_case "val_over_2hex" 1 -f /tmp/tc_val_3hex.txt

# 3. devmem read error
# When 0x838 version read fails -> rc=4
export MOCK_FAIL_READ=1
run_case "devmem_ver_read_fail" 4 -f "$SCRIPT_DIR/test_tune.txt"
unset MOCK_FAIL_READ

# When 0x8FC status read fails during write -> rc=2
export MOCK_FAIL_REG_READ=1
run_case "devmem_reg_read_fail" 2 -f "$SCRIPT_DIR/test_tune.txt"
unset MOCK_FAIL_REG_READ

# Clean temporary test files
rm -f /tmp/tc_*.txt "$STATE_FILE"

echo "================================================================"
if [ $FAIL_CNT -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL_CNT TESTS FAILED"
    exit 1
fi
