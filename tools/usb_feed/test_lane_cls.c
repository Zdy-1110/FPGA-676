#define _GNU_SOURCE
#define LANE_CLS_TEST 1
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>

#include "lane_cls.c"

static void test_continuous_high_to_solid(void)
{
    printf("[TEST 1] Continuous high max_consec -> solid\n");
    lane_cls_test_init("win", 30, 60, 40, 10);

    LaneSide side_l;
    memset(&side_l, 0, sizeof(side_l));
    side_l.side = 0;
    side_l.solid = 0;

    LaneSample ring[64];
    memset(ring, 0, sizeof(ring));

    /* 持续输入 40 帧 max_consec=80（高于 T_ON=60） */
    for (int i = 0; i < 40; i++) {
        LaneSample smp;
        memset(&smp, 0, sizeof(smp));
        smp.frame_cnt = (uint8_t)i;
        smp.max_consec_l = 80;
        smp.fpga_valid_l = 1;
        smp.fpga_solid_l = 0; /* FPGA 原始为虚，验证 RK 分类器判定为实 */

        int slot = (i < 64) ? i : 63;
        if (i >= 64) {
            memmove(&ring[0], &ring[1], sizeof(LaneSample) * 63);
        }
        ring[slot] = smp;

        int n = (i + 1 < 64) ? (i + 1) : 64;
        lane_cls_update(&side_l, ring, n);
    }

    assert(side_l.valid == 1);
    assert(side_l.solid == 1);
    printf("  PASS: solid=%d valid=%d (continuous mc=80)\n", side_l.solid, side_l.valid);
}

static void test_periodic_drop_to_dashed(void)
{
    printf("[TEST 2] Periodic drop (cycle 30, drop to 20) -> dashed\n");
    lane_cls_test_init("win", 30, 60, 40, 10);

    LaneSide side_l;
    memset(&side_l, 0, sizeof(side_l));
    side_l.side = 0;
    side_l.solid = 1; /* 从实线状态开始，验证跌落触发退出实线 */

    LaneSample ring[64];
    memset(ring, 0, sizeof(ring));

    /* 模拟虚线：30 帧周期内，前 8 帧跌落至 mc=20，其余 22 帧 mc=80 */
    for (int i = 0; i < 90; i++) {
        int phase = i % 30;
        uint8_t mc = (phase < 8) ? 20 : 80;

        LaneSample smp;
        memset(&smp, 0, sizeof(smp));
        smp.frame_cnt = (uint8_t)i;
        smp.max_consec_l = mc;
        smp.fpga_valid_l = 1;
        smp.fpga_solid_l = 1; /* FPGA 为实，验证 RK 时序分类器正确识别出虚线 */

        int n = (i + 1 < 64) ? (i + 1) : 64;
        if (i < 64) {
            ring[i] = smp;
        } else {
            memmove(&ring[0], &ring[1], sizeof(LaneSample) * 63);
            ring[63] = smp;
        }

        lane_cls_update(&side_l, ring, n);
    }

    assert(side_l.valid == 1);
    assert(side_l.solid == 0);
    printf("  PASS: solid=%d valid=%d (periodic drop to 20)\n", side_l.solid, side_l.valid);
}

static void test_fpga_passthrough(void)
{
    printf("[TEST 3] FPGA mode pass-through\n");
    lane_cls_test_init("fpga", 30, 60, 40, 10);

    LaneSide side_l;
    memset(&side_l, 0, sizeof(side_l));
    side_l.side = 0;

    LaneSide side_r;
    memset(&side_r, 0, sizeof(side_r));
    side_r.side = 1;

    LaneSample smp;
    memset(&smp, 0, sizeof(smp));

    /* Case A: L solid, R dashed */
    smp.fpga_valid_l = 1;
    smp.fpga_solid_l = 1;
    smp.max_consec_l = 10; /* 低 mc，但 fpga 模式必须忠实透传 solid=1 */
    smp.fpga_valid_r = 1;
    smp.fpga_solid_r = 0;
    smp.max_consec_r = 120; /* 高 mc，但 fpga 模式必须忠实透传 solid=0 */

    lane_cls_update(&side_l, &smp, 1);
    lane_cls_update(&side_r, &smp, 1);
    assert(side_l.valid == 1 && side_l.solid == 1);
    assert(side_r.valid == 1 && side_r.solid == 0);

    /* Case B: L invalid, R solid */
    smp.fpga_valid_l = 0;
    smp.fpga_solid_l = 0;
    smp.fpga_valid_r = 1;
    smp.fpga_solid_r = 1;

    lane_cls_update(&side_l, &smp, 1);
    lane_cls_update(&side_r, &smp, 1);
    assert(side_l.valid == 0 && side_l.solid == 0);
    assert(side_r.valid == 1 && side_r.solid == 1);

    printf("  PASS: fpga passthrough verified for both sides\n");
}

static void test_frame_cnt_wraparound(void)
{
    printf("[TEST 4] frame_cnt wraparound and drop detection\n");

    /* 连续递增无丢帧：254 -> 255 -> 0 -> 1 */
    assert(lane_cls_calc_drop(255, 254) == 0);
    assert(lane_cls_calc_drop(0, 255) == 0);   /* 8位回绕 255 -> 0 */
    assert(lane_cls_calc_drop(1, 0) == 0);

    /* 完整循环 0..255..0 */
    uint32_t total_drop = 0;
    for (int i = 0; i < 512; i++) {
        uint8_t prev = (uint8_t)i;
        uint8_t curr = (uint8_t)(i + 1);
        total_drop += lane_cls_calc_drop(curr, prev);
    }
    assert(total_drop == 0);

    /* 跳帧/丢帧测试 */
    /* 254 -> 1: 实际前进了 3 帧 (255, 0, 1)，跳过了 2 帧 */
    assert(lane_cls_calc_drop(1, 254) == 2);

    /* 255 -> 2: 实际前进了 3 帧 (0, 1, 2)，跳过了 2 帧 */
    assert(lane_cls_calc_drop(2, 255) == 2);

    /* 10 -> 15: 前进 5 帧，跳过 4 帧 */
    assert(lane_cls_calc_drop(15, 10) == 4);

    /* 同一帧重复读取: diff=0，应为 0 */
    assert(lane_cls_calc_drop(50, 50) == 0);

    printf("  PASS: 0 drops on 255->0 wraparound, exact drop counts on jumps\n");
}

/* bucket 模式：喂一个固定 mc 序列 n 帧，返回最终 solid */
static int bucket_feed(int side, int mc, int frames, int valid)
{
    LaneSide s;
    memset(&s, 0, sizeof(s));
    s.side = side;
    LaneSample smp;
    for (int i = 0; i < frames; i++) {
        memset(&smp, 0, sizeof(smp));
        smp.frame_cnt = (uint8_t)i;
        smp.max_consec_l = (uint8_t)mc; smp.fpga_valid_l = (uint8_t)valid;
        smp.max_consec_r = (uint8_t)mc; smp.fpga_valid_r = (uint8_t)valid;
        lane_cls_update(&s, &smp, 1);
    }
    return s.solid;
}

static void test_bucket(void)
{
    printf("[TEST 5] bucket mode (asymmetric leaky bucket)\n");
    lane_cls_test_init("bucket", 30, 60, 40, 10);
    assert(bucket_feed(0, 40, 5, 1) == 0);   /* 左 5 帧 x(+5)=25 < 30 */
    assert(bucket_feed(0, 40, 6, 1) == 1);   /* 左 6 帧 = 30 → 实线 */
    assert(bucket_feed(0, 34, 50, 1) == 0);  /* 左 mc<35 永远虚线 */
    assert(bucket_feed(1, 60, 100, 1) == 0); /* 右 mc<75 永远虚线 */
    assert(bucket_feed(1, 80, 23, 1) == 0);  /* 右 23 帧 x(+3)=69 < 70 */
    assert(bucket_feed(1, 80, 24, 1) == 1);  /* 右 24 帧 = 72 → 实线 */
    assert(bucket_feed(0, 80, 50, 0) == 0);  /* 无效 → 清零 */
    printf("  PASS: thresholds/steps match exp_temporal_20261102 scheme (e)\n");
}

int main(void)
{
    printf("=== Running lane_cls unit tests ===\n");
    test_continuous_high_to_solid();
    test_periodic_drop_to_dashed();
    test_fpga_passthrough();
    test_frame_cnt_wraparound();
    test_bucket();
    printf("=== ALL TESTS PASSED ===\n");
    return 0;
}
