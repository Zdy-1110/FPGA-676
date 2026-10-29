#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "quad_sched.h"
#include "npu_post.h"

static void test_a_swrr(void)
{
    printf("[Test A] SWRR weighting and masking...\n");
    quad_swrr_t swrr;
    int weights[4] = {2, 1, 1, 1};
    quad_swrr_init(&swrr, weights, 0x0F);

    int count[4] = {0};
    for (int i = 0; i < 50; i++) {
        int ch = quad_swrr_next(&swrr);
        assert(ch >= 0 && ch < 4);
        count[ch]++;
    }
    printf("  50 runs with w=(2,1,1,1): ch0=%d, ch1=%d, ch2=%d, ch3=%d\n",
           count[0], count[1], count[2], count[3]);
    assert(count[0] == 20);
    assert(count[1] == 10);
    assert(count[2] == 10);
    assert(count[3] == 10);

    /* Mask out ch0 -> valid mask 0x0E (ch1, ch2, ch3) */
    quad_swrr_set_mask(&swrr, 0x0E);
    int count2[4] = {0};
    for (int i = 0; i < 30; i++) {
        int ch = quad_swrr_next(&swrr);
        assert(ch >= 1 && ch <= 3);
        count2[ch]++;
    }
    printf("  30 runs with ch0 masked: ch0=%d, ch1=%d, ch2=%d, ch3=%d\n",
           count2[0], count2[1], count2[2], count2[3]);
    assert(count2[0] == 0);
    assert(count2[1] == 10);
    assert(count2[2] == 10);
    assert(count2[3] == 10);
    printf("  [PASS] Test A\n");
}

static void test_b_coordinates(void)
{
    printf("[Test B] Band to screen coordinate conversion and clamping...\n");
    /* ch3: slot origin is (960, 540)
     * band box (0,0)-(959,319) -> screen (960, 720)-(1919, 1039)
     */
    int32_t sx0, sy0, sx1, sy1;
    quad_band_to_screen_box(3, 0.0f, 0.0f, 959.0f, 319.0f, &sx0, &sy0, &sx1, &sy1);
    printf("  ch3 (0,0)-(959,319) -> screen (%d,%d)-(%d,%d)\n", sx0, sy0, sx1, sy1);
    assert(sx0 == 960);
    assert(sy0 == 720);
    assert(sx1 == 1919);
    assert(sy1 == 1039);

    /* Out of bounds clamping in ch3 (slot bounds: [960, 1919] x [540, 1079]) */
    quad_band_to_screen_box(3, -200.0f, -300.0f, 2000.0f, 1000.0f, &sx0, &sy0, &sx1, &sy1);
    printf("  ch3 out of bounds (-200,-300)-(2000,1000) -> clamped (%d,%d)-(%d,%d)\n",
           sx0, sy0, sx1, sy1);
    assert(sx0 == 960);
    assert(sy0 == 540);
    assert(sx1 == 1919);
    assert(sy1 == 1079);
    printf("  [PASS] Test B\n");
}

static void test_c_band_rect(void)
{
    printf("[Test C] Band rect calculation...\n");
    quad_rect_t r;

    /* 1920x1080 -> (0, 360, 1920, 640) */
    quad_calc_band_rect(1920, 1080, &r);
    printf("  1920x1080 -> (%d, %d, %d, %d)\n", r.x, r.y, r.w, r.h);
    assert(r.x == 0 && r.y == 360 && r.w == 1920 && r.h == 640);

    /* 960x540 -> (0, 180, 960, 320) */
    quad_calc_band_rect(960, 540, &r);
    printf("  960x540 -> (%d, %d, %d, %d)\n", r.x, r.y, r.w, r.h);
    assert(r.x == 0 && r.y == 180 && r.w == 960 && r.h == 320);

    /* 1280x720 -> y and h must be even */
    quad_calc_band_rect(1280, 720, &r);
    printf("  1280x720 -> (%d, %d, %d, %d)\n", r.x, r.y, r.w, r.h);
    assert(r.x == 0 && r.w == 1280);
    assert((r.y % 2) == 0);
    assert((r.h % 2) == 0);
    printf("  [PASS] Test C\n");
}

static void test_d_pack_consistency(void)
{
    printf("[Test D] Packing consistency with npu_pack_box_regs...\n");
    npu_det_t det;
    memset(&det, 0, sizeof(det));
    det.cls = 2; /* car -> color 5 */
    det.score = 0.85f;
    det.x0 = 120.0f;
    det.y0 = 450.0f;
    det.x1 = 300.0f;
    det.y1 = 600.0f;

    uint32_t dw0 = 0, dw1 = 0;
    quad_pack_single_box(&det, &dw0, &dw1);

    uint32_t regs[32] = {0};
    npu_pack_box_regs(&det, 1, regs);

    printf("  single_box: dw0=0x%08X dw1=0x%08X\n", dw0, dw1);
    printf("  npu_pack:   dw0=0x%08X dw1=0x%08X\n", regs[0], regs[1]);
    assert(dw0 == regs[0]);
    assert(dw1 == regs[1]);
    assert(dw0 != 0 && dw1 != 0);

    /* Also test multiple classes */
    for (int cls = 0; cls < 9; cls++) {
        det.cls = cls;
        quad_pack_single_box(&det, &dw0, &dw1);
        npu_pack_box_regs(&det, 1, regs);
        assert(dw0 == regs[0]);
        assert(dw1 == regs[1]);
    }
    printf("  [PASS] Test D\n");
}

static void test_e_diff_empty_on_consecutive(void)
{
    printf("[Test E] Consecutive submission produces empty diff...\n");
    quad_osd_cache_t cache;
    quad_osd_cache_init(&cache);

    npu_det_t top4[4];
    memset(top4, 0, sizeof(top4));
    top4[0].cls = 0; top4[0].score = 0.9f; top4[0].x0 = 10; top4[0].y0 = 20; top4[0].x1 = 50; top4[0].y1 = 100;
    top4[1].cls = 2; top4[1].score = 0.8f; top4[1].x0 = 60; top4[1].y0 = 30; top4[1].x1 = 120; top4[1].y1 = 200;

    uint32_t regs[8];
    quad_pack_ch_regs(top4, 2, regs);

    quad_reg_write_t writes[16];
    int nw1 = quad_sched_diff_ch_regs(&cache, 1, regs, writes, 16);
    printf("  First submit: %d writes emitted\n", nw1);
    assert(nw1 > 0);

    int nw2 = quad_sched_diff_ch_regs(&cache, 1, regs, writes, 16);
    printf("  Second submit: %d writes emitted\n", nw2);
    assert(nw2 == 0);
    printf("  [PASS] Test E\n");
}

static void test_f_timeout_clear(void)
{
    printf("[Test F] Timeout clear emits only low DW writes with 0...\n");
    quad_osd_cache_t cache;
    quad_osd_cache_init(&cache);

    /* Populate channel 2 with some boxes */
    npu_det_t top4[4];
    memset(top4, 0, sizeof(top4));
    for (int k = 0; k < 4; k++) {
        top4[k].cls = 2;
        top4[k].score = 0.9f;
        top4[k].x0 = 100 + k * 10;
        top4[k].y0 = 200 + k * 10;
        top4[k].x1 = 300 + k * 10;
        top4[k].y1 = 400 + k * 10;
    }
    uint32_t regs[8];
    quad_pack_ch_regs(top4, 4, regs);

    quad_reg_write_t writes[16];
    int nw = quad_sched_diff_ch_regs(&cache, 2, regs, writes, 16);
    assert(nw == 8);

    /* Timeout clear on ch2 */
    quad_reg_write_t clr_writes[16];
    int clr_n = quad_sched_timeout_clear_ch(&cache, 2, clr_writes, 16);
    printf("  Timeout clear returned %d writes\n", clr_n);
    assert(clr_n == 4);

    for (int k = 0; k < 4; k++) {
        uint32_t expected_offset = 0x900u + (uint32_t)((2 * 4 + k) * 8);
        assert(clr_writes[k].offset == expected_offset);
        assert(clr_writes[k].val == 0);
    }

    /* Verify shadow low words are 0, high words unchanged */
    for (int k = 0; k < 4; k++) {
        int low_idx = 2 * 8 + k * 2;
        int high_idx = 2 * 8 + k * 2 + 1;
        assert(cache.shadow[low_idx] == 0);
        assert(cache.shadow[high_idx] != 0);
    }
    printf("  [PASS] Test F\n");
}

static void test_g_select_sorting(void)
{
    printf("[Test G] Selection sorting rule (score desc, same score by original index asc)...\n");
    npu_det_t dets[6];
    memset(dets, 0, sizeof(dets));

    dets[0].cls = 2; dets[0].score = 0.80f; dets[0].y1 = 100.0f; /* 3rd */
    dets[1].cls = 2; dets[1].score = 0.90f; dets[1].y1 = 200.0f; /* 1st (orig_idx 1 < 4) */
    dets[2].cls = 2; dets[2].score = 0.50f; dets[2].y1 = 200.0f; /* 5th (not in top4) */
    dets[3].cls = 2; dets[3].score = 0.10f; dets[3].y1 = 300.0f; /* score < 0.25 -> filtered out */
    dets[4].cls = 2; dets[4].score = 0.90f; dets[4].y1 = 250.0f; /* 2nd (orig_idx 4 > 1) */
    dets[5].cls = 2; dets[5].score = 0.70f; dets[5].y1 = 200.0f; /* 4th */

    npu_det_t top4[4];
    int n = quad_select_top4(dets, 6, 0.25f, top4);
    printf("  Part 1: Selected %d boxes:\n", n);
    for (int i = 0; i < n; i++) {
        printf("    #%d: score=%.2f y1=%.1f\n", i, top4[i].score, top4[i].y1);
    }
    assert(n == 4);
    /* 1st: dets[1] (score 0.90, orig_idx 1) */
    assert(top4[0].score == 0.90f && top4[0].y1 == 200.0f);
    /* 2nd: dets[4] (score 0.90, orig_idx 4) */
    assert(top4[1].score == 0.90f && top4[1].y1 == 250.0f);
    /* 3rd: dets[0] (score 0.80, orig_idx 0) */
    assert(top4[2].score == 0.80f && top4[2].y1 == 100.0f);
    /* 4th: dets[5] (score 0.70, orig_idx 5) */
    assert(top4[3].score == 0.70f && top4[3].y1 == 200.0f);

    /* Part 2: 新增用例 - 3 个 y1=320 的低分框 (0.26/0.30/0.38) + 3 个高分框 (0.98/0.94/0.88) */
    printf("  Part 2: 3 edge low-score (y1=320) + 3 high-score boxes...\n");
    npu_det_t dets2[6];
    memset(dets2, 0, sizeof(dets2));
    dets2[0].cls = 2; dets2[0].score = 0.26f; dets2[0].y1 = 320.0f;
    dets2[1].cls = 2; dets2[1].score = 0.98f; dets2[1].y1 = 150.0f;
    dets2[2].cls = 2; dets2[2].score = 0.30f; dets2[2].y1 = 320.0f;
    dets2[3].cls = 2; dets2[3].score = 0.94f; dets2[3].y1 = 180.0f;
    dets2[4].cls = 2; dets2[4].score = 0.38f; dets2[4].y1 = 320.0f;
    dets2[5].cls = 2; dets2[5].score = 0.88f; dets2[5].y1 = 200.0f;

    npu_det_t top4_2[4];
    int n2 = quad_select_top4(dets2, 6, 0.25f, top4_2);
    printf("  Selected %d boxes:\n", n2);
    for (int i = 0; i < n2; i++) {
        printf("    #%d: score=%.2f y1=%.1f\n", i, top4_2[i].score, top4_2[i].y1);
    }
    assert(n2 == 4);
    assert(top4_2[0].score == 0.98f);
    assert(top4_2[1].score == 0.94f);
    assert(top4_2[2].score == 0.88f);
    assert(top4_2[3].score == 0.38f);
    printf("  [PASS] Test G\n");
}

int main(void)
{
    printf("=== Running quad_sched Unit Tests ===\n");
    test_a_swrr();
    test_b_coordinates();
    test_c_band_rect();
    test_d_pack_consistency();
    test_e_diff_empty_on_consecutive();
    test_f_timeout_clear();
    test_g_select_sorting();
    printf("ALL PASS\n");
    return 0;
}
