#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "adas_dec.h"

static int g_tests_run = 0;
static int g_tests_failed = 0;

static void check_case(const char *name, int lane, const int sig[3], int moving, uint32_t expected)
{
    g_tests_run++;
    uint32_t actual = adas_lane_signal_dec(lane, sig, moving);
    if (actual != expected) {
        g_tests_failed++;
        fprintf(stderr, "FAIL: %s\n", name);
        fprintf(stderr, "  Input: lane=%d, sig={%d,%d,%d}, moving=%d\n",
                lane, sig[0], sig[1], sig[2], moving);
        fprintf(stderr, "  Expected: 0x%03X, Actual: 0x%03X\n", expected, actual);
    }
}

static void check_hazard_case(const char *name, int cls, float score,
                              float x0, float y0, float x1, float y1,
                              int moving, int expected)
{
    g_tests_run++;
    int actual = adas_box_hazard(cls, score, x0, y0, x1, y1, moving);
    if (actual != expected) {
        g_tests_failed++;
        fprintf(stderr, "FAIL: %s\n", name);
        fprintf(stderr, "  Input: cls=%d, score=%.2f, box=[%.1f,%.1f,%.1f,%.1f], moving=%d\n",
                cls, score, x0, y0, x1, y1, moving);
        fprintf(stderr, "  Expected: %d, Actual: %d\n", expected, actual);
    }
}

int main(void)
{
    printf("Running ADAS decision unit tests...\n");

    /* 1. 三车道 x {红, 黄, 绿, 无} x moving{0, 1} (专用灯有信号的情况) */
    const int colors[4] = { 0, 1, 2, 3 };
    const char *color_names[4] = { "NONE", "RED", "YEL", "GRN" };

    for (int lane = 0; lane < 3; lane++) {
        for (int c_idx = 0; c_idx < 4; c_idx++) {
            int c = colors[c_idx];
            for (int moving = 0; moving <= 1; moving++) {
                int sig[3] = { 0, 0, 0 };
                sig[lane] = c;

                uint32_t expected = 0;
                if (c == 1 || c == 2) {
                    expected = (3u << (2 * lane)) | (moving ? (1u << 8) : 0);
                } else if (c == 3) {
                    expected = 2u << (2 * lane);
                } else {
                    /* c == 0 */
                    if (lane == 0) {
                        /* 左车道左灯无，且 sig[1] 也为 0 -> 仍为 0 -> 2u << 2 (直行绿) */
                        expected = 2u << 2;
                    } else if (lane == 2) {
                        /* 右车道右灯无 -> 右转不受灯控 -> 2u << 4 (右箭头绿，无告警) */
                        expected = 2u << 4;
                    } else {
                        /* lane == 1, sig[1] 为 0 -> 2u << 2 (直行绿) */
                        expected = 2u << 2;
                    }
                }

                char desc[128];
                snprintf(desc, sizeof(desc), "Matrix: lane=%d, sig[%d]=%s, moving=%d",
                         lane, lane, color_names[c_idx], moving);
                check_case(desc, lane, sig, moving, expected);
            }
        }
    }

    /* 2. 左车道左灯无 + 直行红 / 绿 */
    {
        /* 左灯无 + 直行红, moving=0 -> 左红无告警 (3u << 0) */
        int sig_red[3] = { 0, 1, 0 };
        check_case("Lane 0: Left NONE + Straight RED, moving=0", 0, sig_red, 0, 3u << 0);

        /* 左灯无 + 直行红, moving=1 -> 左红带告警 (3u << 0) | (1u << 8) */
        check_case("Lane 0: Left NONE + Straight RED, moving=1", 0, sig_red, 1, (3u << 0) | (1u << 8));

        /* 左灯无 + 直行黄, moving=0 -> 左红无告警 (3u << 0) */
        int sig_yel[3] = { 0, 2, 0 };
        check_case("Lane 0: Left NONE + Straight YEL, moving=0", 0, sig_yel, 0, 3u << 0);

        /* 左灯无 + 直行黄, moving=1 -> 左红带告警 (3u << 0) | (1u << 8) */
        check_case("Lane 0: Left NONE + Straight YEL, moving=1", 0, sig_yel, 1, (3u << 0) | (1u << 8));

        /* 左灯无 + 直行绿, moving=0/1 -> 左绿 (2u << 0) */
        int sig_grn[3] = { 0, 3, 0 };
        check_case("Lane 0: Left NONE + Straight GRN, moving=0", 0, sig_grn, 0, 2u << 0);
        check_case("Lane 0: Left NONE + Straight GRN, moving=1", 0, sig_grn, 1, 2u << 0);
    }

    /* 3. 右车道右灯无 + 直行红 (应为右绿无告警: 2u << 4) */
    {
        int sig_st_red[3] = { 0, 1, 0 };
        check_case("Lane 2: Right NONE + Straight RED, moving=0", 2, sig_st_red, 0, 2u << 4);
        check_case("Lane 2: Right NONE + Straight RED, moving=1", 2, sig_st_red, 1, 2u << 4);
    }

    /* 4. 右车道右灯红 (红 + moving 告警) */
    {
        int sig_rt_red[3] = { 0, 0, 1 };
        check_case("Lane 2: Right RED, moving=0", 2, sig_rt_red, 0, 3u << 4);
        check_case("Lane 2: Right RED, moving=1", 2, sig_rt_red, 1, (3u << 4) | (1u << 8));
    }

    /* 5. 全无灯 (直行绿: 2u << 2) */
    {
        int sig_none[3] = { 0, 0, 0 };
        /* 直行车道全无灯 -> 直行绿 */
        check_case("Lane 1: All NONE, moving=0", 1, sig_none, 0, 2u << 2);
        check_case("Lane 1: All NONE, moving=1", 1, sig_none, 1, 2u << 2);

        /* 左车道全无灯 (左跟随直行，直行为 0，仍为 0 -> 直行绿) */
        check_case("Lane 0: All NONE, moving=0", 0, sig_none, 0, 2u << 2);
        check_case("Lane 0: All NONE, moving=1", 0, sig_none, 1, 2u << 2);
    }

    /* 6. 额外边界测试: lane 越界 (< 0 或 > 2 按 1 处理) */
    {
        int sig_straight_red[3] = { 0, 1, 0 };
        check_case("Lane -1: OOB -> Lane 1, Straight RED, moving=1", -1, sig_straight_red, 1, (3u << 2) | (1u << 8));
        check_case("Lane 5: OOB -> Lane 1, Straight RED, moving=0", 5, sig_straight_red, 0, 3u << 2);
    }

    /* 7. Hazard 目标检测报警测试 (adas_box_hazard) */
    {
        /* 7.1 行人在中间带框底 0.76 -> 报警 */
        float ped_cx = 0.50f * 960.0f;
        float ped_w = 0.08f * 960.0f;
        check_hazard_case("Pedestrian center y1=0.76 -> hazard",
                          0, 0.50f, ped_cx - ped_w * 0.5f, 0.50f * 540.0f,
                          ped_cx + ped_w * 0.5f, 0.76f * 540.0f, 0, 1);

        /* 7.2 车辆框底 0.85 宽 0.14x960 -> 不报警 (不够大) */
        float veh_cx = 0.50f * 960.0f;
        float veh_w_narrow = 0.14f * 960.0f;
        check_hazard_case("Vehicle y1=0.85 w=0.14 (narrow) -> no hazard",
                          2, 0.50f, veh_cx - veh_w_narrow * 0.5f, 0.50f * 540.0f,
                          veh_cx + veh_w_narrow * 0.5f, 0.85f * 540.0f, 1, 0);

        /* 7.3 车辆框底 0.85 宽 0.25x960 moving=1 -> 报警 */
        float veh_w_wide = 0.25f * 960.0f;
        check_hazard_case("Vehicle y1=0.85 w=0.25 moving=1 -> hazard",
                          2, 0.50f, veh_cx - veh_w_wide * 0.5f, 0.50f * 540.0f,
                          veh_cx + veh_w_wide * 0.5f, 0.85f * 540.0f, 1, 1);

        /* 7.4 车辆框底 0.85 宽 0.25x960 moving=0 -> 不报警 */
        check_hazard_case("Vehicle y1=0.85 w=0.25 moving=0 -> no hazard",
                          2, 0.50f, veh_cx - veh_w_wide * 0.5f, 0.50f * 540.0f,
                          veh_cx + veh_w_wide * 0.5f, 0.85f * 540.0f, 0, 0);

        /* 7.5 车辆在边上 (cx=0.8) -> 不报警 */
        float veh_cx_side = 0.80f * 960.0f;
        check_hazard_case("Vehicle side cx=0.8 -> no hazard",
                          2, 0.50f, veh_cx_side - veh_w_wide * 0.5f, 0.50f * 540.0f,
                          veh_cx_side + veh_w_wide * 0.5f, 0.85f * 540.0f, 1, 0);
    }

    printf("ADAS decision unit tests finished: %d run, %d failed.\n", g_tests_run, g_tests_failed);

    if (g_tests_failed > 0) {
        return 1;
    }
    printf("ALL TESTS PASSED.\n");
    return 0;
}
