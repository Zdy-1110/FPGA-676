#include "../npu_post.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>

static int g_failed = 0;

#define TEST_CHECK(cond, msg) do { \
    if (!(cond)) { \
        printf("[FAIL] %s:%d: %s\n", __FILE__, __LINE__, msg); \
        g_failed++; \
    } \
} while (0)

static void test_map_to_src(void) {
    printf("Running test_map_to_src...\n");
    float sx0, sy0, sx1, sy1;

    /* Normal within range: (100, 50, 200, 100) -> (200, 460, 400, 560) */
    npu_map_to_src(100.0f, 50.0f, 200.0f, 100.0f, &sx0, &sy0, &sx1, &sy1);
    TEST_CHECK(fabsf(sx0 - 200.0f) < 1e-4f, "sx0 within range");
    TEST_CHECK(fabsf(sy0 - 460.0f) < 1e-4f, "sy0 within range");
    TEST_CHECK(fabsf(sx1 - 400.0f) < 1e-4f, "sx1 within range");
    TEST_CHECK(fabsf(sy1 - 560.0f) < 1e-4f, "sy1 within range");

    /* Negative truncation: (-25.0f, -200.0f, 100.0f, 50.0f) */
    /* x0 = -50 -> 0; y0 = -400 + 360 = -40 -> 0 */
    npu_map_to_src(-25.0f, -200.0f, 100.0f, 50.0f, &sx0, &sy0, &sx1, &sy1);
    TEST_CHECK(sx0 == 0.0f, "sx0 truncated to 0");
    TEST_CHECK(sy0 == 0.0f, "sy0 truncated to 0");
    TEST_CHECK(fabsf(sx1 - 200.0f) < 1e-4f, "sx1 unchanged");
    TEST_CHECK(fabsf(sy1 - 460.0f) < 1e-4f, "sy1 unchanged");

    /* Upper bound truncation: (100.0f, 50.0f, 1200.0f, 400.0f) */
    /* x1 = 2400 -> 1919; y1 = 800 + 360 = 1160 -> 1079 */
    npu_map_to_src(100.0f, 50.0f, 1200.0f, 400.0f, &sx0, &sy0, &sx1, &sy1);
    TEST_CHECK(fabsf(sx0 - 200.0f) < 1e-4f, "sx0 unchanged");
    TEST_CHECK(fabsf(sy0 - 460.0f) < 1e-4f, "sy0 unchanged");
    TEST_CHECK(sx1 == 1919.0f, "sx1 truncated to 1919");
    TEST_CHECK(sy1 == 1079.0f, "sy1 truncated to 1079");

    /* Array wrapper test */
    npu_det_t in_det = { .cls = 2, .score = 0.8f, .x0 = -10.0f, .y0 = -10.0f, .x1 = 1000.0f, .y1 = 500.0f };
    npu_det_t out_det;
    npu_map_dets_to_src(&in_det, &out_det, 1);
    TEST_CHECK(out_det.x0 == 0.0f, "array x0 clamped");
    TEST_CHECK(out_det.y0 == 340.0f, "array y0 = -20 + 360 = 340");
    TEST_CHECK(out_det.x1 == 1919.0f, "array x1 clamped to 1919");
    TEST_CHECK(out_det.y1 == 1079.0f, "array y1 clamped to 1079");
    TEST_CHECK(out_det.cls == 2, "cls preserved");
    TEST_CHECK(out_det.score == 0.8f, "score preserved");
}

static void test_pack_box_regs(void) {
    printf("Running test_pack_box_regs...\n");
    uint32_t regs[32];

    /* 1. Bit layout check */
    npu_det_t single_det = {
        .cls = 0, /* person -> color 3 */
        .score = 0.95f,
        .x0 = 123.0f,
        .y0 = 456.0f,
        .x1 = 789.0f,
        .y1 = 1011.0f
    };
    npu_pack_box_regs(&single_det, 1, regs);

    /* DW0: color[31:28]=3, y0[27:16]=456 (0x1C8), 4'b0[15:12]=0, x0[11:0]=123 (0x07B) */
    uint32_t exp_dw0 = ((uint32_t)3 << 28) | ((uint32_t)456 << 16) | (uint32_t)123;
    /* DW1: 4'b0[31:28]=0, y1[27:16]=1011 (0x3F3), 4'b0[15:12]=0, x1[11:0]=789 (0x315) */
    uint32_t exp_dw1 = ((uint32_t)1011 << 16) | (uint32_t)789;

    TEST_CHECK(regs[0] == exp_dw0, "DW0 bit layout");
    TEST_CHECK(regs[1] == exp_dw1, "DW1 bit layout");

    /* 2. color=0 padding for unused slots */
    for (int i = 2; i < 32; ++i) {
        TEST_CHECK(regs[i] == 0, "unused slots must be 0");
    }

    /* 3. Sorting by score descending */
    npu_det_t three_dets[3] = {
        { .cls = 1, .score = 0.30f, .x0 = 10.0f, .y0 = 10.0f, .x1 = 20.0f, .y1 = 20.0f }, /* rider: 6 */
        { .cls = 2, .score = 0.90f, .x0 = 30.0f, .y0 = 30.0f, .x1 = 40.0f, .y1 = 40.0f }, /* car: 5 */
        { .cls = 5, .score = 0.60f, .x0 = 50.0f, .y0 = 50.0f, .x1 = 60.0f, .y1 = 60.0f }, /* tricycle: 4 */
    };
    npu_pack_box_regs(three_dets, 3, regs);
    /* Top 1 should be car (score 0.90, color 5) */
    TEST_CHECK(((regs[0] >> 28) & 0xF) == 5, "top 1 is car (color 5)");
    /* Top 2 should be tricycle (score 0.60, color 4) */
    TEST_CHECK(((regs[2] >> 28) & 0xF) == 4, "top 2 is tricycle (color 4)");
    /* Top 3 should be rider (score 0.30, color 6) */
    TEST_CHECK(((regs[4] >> 28) & 0xF) == 6, "top 3 is rider (color 6)");
    /* Remainder unused (color 0) */
    for (int i = 6; i < 32; ++i) {
        TEST_CHECK(regs[i] == 0, "slots 3..15 must be 0");
    }

    /* 4. 16 boxes cap */
    npu_det_t many_dets[25];
    for (int i = 0; i < 25; ++i) {
        many_dets[i].cls = (i % 9);
        many_dets[i].score = (float)i * 0.04f; /* 0.00 to 0.96 */
        many_dets[i].x0 = 10.0f + (float)i;
        many_dets[i].y0 = 20.0f + (float)i;
        many_dets[i].x1 = 30.0f + (float)i;
        many_dets[i].y1 = 40.0f + (float)i;
    }
    npu_pack_box_regs(many_dets, 25, regs);
    /* Top 16 are i = 24 down to 9 (scores 0.96 down to 0.36) */
    for (int slot = 0; slot < 16; ++slot) {
        int expected_orig_i = 24 - slot;
        uint8_t exp_color = npu_class_to_color(expected_orig_i % 9);
        uint8_t act_color = (uint8_t)((regs[2 * slot] >> 28) & 0xF);
        TEST_CHECK(act_color == exp_color, "color matches top 16 sorted order");
        uint32_t act_x0 = regs[2 * slot] & 0xFFF;
        TEST_CHECK(act_x0 == (uint32_t)(10 + expected_orig_i), "x0 matches sorted order");
    }
}

static void test_format_npu_line(void) {
    printf("Running test_format_npu_line...\n");
    char line[64];
    memset(line, 0xFF, sizeof(line));

    npu_format_npu_line(line, 30, 25, 12);
    /* Should start with "NPU 30 fps 25 ms n=12" */
    const char *prefix = "NPU 30 fps 25 ms n=12";
    size_t prefix_len = strlen(prefix);
    TEST_CHECK(memcmp(line, prefix, prefix_len) == 0, "prefix matches");
    /* Remainder up to 64 bytes should be spaces (0x20) */
    for (size_t i = prefix_len; i < 64; ++i) {
        TEST_CHECK(line[i] == ' ', "padded with space");
    }

    /* Test another number */
    npu_format_npu_line(line, 5, 8, 3);
    const char *prefix2 = "NPU 5 fps 8 ms n=3";
    size_t prefix2_len = strlen(prefix2);
    TEST_CHECK(memcmp(line, prefix2, prefix2_len) == 0, "prefix2 matches");
    for (size_t i = prefix2_len; i < 64; ++i) {
        TEST_CHECK(line[i] == ' ', "prefix2 padded with space");
    }
}

static void test_quant_threshold(void) {
    printf("Running test_quant_threshold...\n");
    /* sum_s8: scale = 0.00392156886, zp = -128, conf = 0.25 */
    /* floor(0.25 / scale + zp) - 1 = floor(63.75 - 128) - 1 = -65 - 1 = -66 */
    float scale = 0.00392156886f;
    int32_t zp = -128;
    float conf = 0.25f;

    int8_t q_thr = npu_quant_conf_threshold(conf, scale, zp);
    /* q_thr should be -66 (with 1-step margin) */
    TEST_CHECK(q_thr == -66, "q_thr for sum_s8 is -66 (1-step margin)");

    /* Extreme values */
    int8_t q_high = npu_quant_conf_threshold(100.0f, scale, zp);
    TEST_CHECK(q_high == 127, "extreme high clamps to 127");

    int8_t q_low = npu_quant_conf_threshold(-100.0f, scale, zp);
    TEST_CHECK(q_low == -128, "extreme low clamps to -128");
}

static void test_sum_filter_margin(void) {
    printf("Running test_sum_filter_margin...\n");
    /* Construct 1 anchor where sum is 1 step lower than max class score */
    /* conf = 0.25f, scale = 1/255 = 0.00392156886f, zp = -128 */
    /* Class 0 has q = -64 => score = (-64 - (-128)) * (1/255) = 64/255 = 0.25098f >= 0.25f */
    /* Sum has q = -65 (1 step lower than class 0!) */
    /* Without margin (q_thr = -64), this would be dropped because -65 < -64 */
    /* With margin (q_thr = -66), -65 >= -66, so it must NOT be dropped! */

    int8_t box_data[64];
    memset(box_data, 0, sizeof(box_data));

    int8_t cls_data[9];
    memset(cls_data, -128, sizeof(cls_data));
    cls_data[0] = -64; /* score ~ 0.25098 */

    int8_t sum_data[1];
    sum_data[0] = -65; /* 1 step lower than cls_data[0] */

    npu_scale_t scales[3];
    memset(scales, 0, sizeof(scales));

    /* Scale 0: 1x1 grid */
    scales[0].stride = 8;
    scales[0].h = 1;
    scales[0].w = 1;

    scales[0].box.data = box_data;
    scales[0].box.scale = 0.13725f;
    scales[0].box.zp = -28;
    scales[0].box.channel_stride = 1;
    scales[0].box.row_stride = 1;
    scales[0].box.col_stride = 1;

    scales[0].cls.data = cls_data;
    scales[0].cls.scale = 0.00392156886f;
    scales[0].cls.zp = -128;
    scales[0].cls.channel_stride = 1;
    scales[0].cls.row_stride = 1;
    scales[0].cls.col_stride = 1;

    scales[0].sum.data = sum_data;
    scales[0].sum.scale = 0.00392156886f;
    scales[0].sum.zp = -128;
    scales[0].sum.channel_stride = 1;
    scales[0].sum.row_stride = 1;
    scales[0].sum.col_stride = 1;

    /* Scales 1 and 2: empty (h=0, w=0) */
    scales[1].stride = 16;
    scales[1].h = 0;
    scales[1].w = 0;
    scales[2].stride = 32;
    scales[2].h = 0;
    scales[2].w = 0;

    npu_post_config_t cfg;
    npu_post_config_init(&cfg);
    cfg.conf_thres = 0.25f;

    npu_det_t out_dets[10];
    int n = npu_post_process_int8(&cfg, scales, out_dets, 10);

    TEST_CHECK(n == 1, "anchor must not be dropped when sum is 1 step lower than cls");
    if (n == 1) {
        TEST_CHECK(out_dets[0].cls == 0, "detected cls == 0");
        TEST_CHECK(out_dets[0].score >= 0.25f, "score >= 0.25f");
    }
}

static void test_4ch_direct_fp32(void) {
    printf("Running test_4ch_direct_fp32...\n");

    /* Allocate 9 tensors across 3 scales */
    /* Scale 0 (stride 8): 40x120 = 4800 anchors */
    float *box_s8 = (float *)calloc(64 * 4800, sizeof(float)); /* 64 ch to also test DFL fallback safely */
    float *cls_s8 = (float *)calloc(9 * 4800, sizeof(float));
    /* Scale 1 (stride 16): 20x60 = 1200 anchors */
    float *box_s16 = (float *)calloc(4 * 1200, sizeof(float));
    float *cls_s16 = (float *)calloc(9 * 1200, sizeof(float));
    /* Scale 2 (stride 32): 10x30 = 300 anchors */
    float *box_s32 = (float *)calloc(4 * 300, sizeof(float));
    float *cls_s32 = (float *)calloc(9 * 300, sizeof(float));

    /* Anchor (col=0, row=0) on scale 0: stride=8, dist=(1,1,1,1) */
    box_s8[0 * 4800 + 0] = 1.0f; /* l */
    box_s8[1 * 4800 + 0] = 1.0f; /* t */
    box_s8[2 * 4800 + 0] = 1.0f; /* r */
    box_s8[3 * 4800 + 0] = 1.0f; /* b */

    /* Non-zero class: cls 2, score 0.85f */
    cls_s8[2 * 4800 + 0] = 0.85f;

    npu_tensor_t tensors[9];
    memset(tensors, 0, sizeof(tensors));

    /* Scale 0 */
    tensors[0].data = box_s8;
    tensors[0].channel_stride = 4800;
    tensors[0].row_stride = 120;
    tensors[0].col_stride = 1;
    tensors[0].n_channels = 4;

    tensors[1].data = cls_s8;
    tensors[1].channel_stride = 4800;
    tensors[1].row_stride = 120;
    tensors[1].col_stride = 1;
    tensors[1].n_channels = 9;

    /* Scale 1 */
    tensors[3].data = box_s16;
    tensors[3].channel_stride = 1200;
    tensors[3].row_stride = 60;
    tensors[3].col_stride = 1;
    tensors[3].n_channels = 4;

    tensors[4].data = cls_s16;
    tensors[4].channel_stride = 1200;
    tensors[4].row_stride = 60;
    tensors[4].col_stride = 1;
    tensors[4].n_channels = 9;

    /* Scale 2 */
    tensors[6].data = box_s32;
    tensors[6].channel_stride = 300;
    tensors[6].row_stride = 30;
    tensors[6].col_stride = 1;
    tensors[6].n_channels = 4;

    tensors[7].data = cls_s32;
    tensors[7].channel_stride = 300;
    tensors[7].row_stride = 30;
    tensors[7].col_stride = 1;
    tensors[7].n_channels = 9;

    npu_post_config_t cfg;
    npu_post_config_init(&cfg);

    npu_det_t dets[10];
    int num_dets = npu_post_process_9tensors_fp32(&cfg, tensors, dets, 10);

    TEST_CHECK(num_dets == 1, "FP32 4-ch: exactly 1 detection");
    if (num_dets > 0) {
        printf("  [FP32 4-ch] det: cls=%d, score=%.4f, box=[%.3f, %.3f, %.3f, %.3f]\n",
               dets[0].cls, dets[0].score, dets[0].x0, dets[0].y0, dets[0].x1, dets[0].y1);
        TEST_CHECK(dets[0].cls == 2, "FP32 4-ch: cls matches expected 2");
        TEST_CHECK(fabsf(dets[0].score - 0.85f) < 1e-4f, "FP32 4-ch: score matches 0.85 within 1e-4");
        TEST_CHECK(fabsf(dets[0].x0 - (-4.0f)) < 1e-3f, "FP32 4-ch: x0 == -4 within 1e-3");
        TEST_CHECK(fabsf(dets[0].y0 - (-4.0f)) < 1e-3f, "FP32 4-ch: y0 == -4 within 1e-3");
        TEST_CHECK(fabsf(dets[0].x1 - 12.0f) < 1e-3f, "FP32 4-ch: x1 == 12 within 1e-3");
        TEST_CHECK(fabsf(dets[0].y1 - 12.0f) < 1e-3f, "FP32 4-ch: y1 == 12 within 1e-3");
    }

    /* Verify n_channels = 64 branches to DFL */
    tensors[0].n_channels = 64;
    npu_det_t dets_64[10];
    int num_dets_64 = npu_post_process_9tensors_fp32(&cfg, tensors, dets_64, 10);
    TEST_CHECK(num_dets_64 == 1, "FP32 64-ch: exactly 1 detection");
    if (num_dets_64 > 0) {
        TEST_CHECK(fabsf(dets_64[0].x0 - (-4.0f)) > 1.0f, "FP32 64-ch: executes DFL instead of direct decode");
    }

    free(box_s8);
    free(cls_s8);
    free(box_s16);
    free(cls_s16);
    free(box_s32);
    free(cls_s32);
}

static void test_4ch_direct_int8(void) {
    printf("Running test_4ch_direct_int8...\n");

    /* Allocate 9 tensors across 3 scales */
    /* Scale 0 (stride 8): 40x120 = 4800 anchors */
    int8_t *box_s8 = (int8_t *)calloc(64 * 4800, sizeof(int8_t));
    int8_t *cls_s8 = (int8_t *)malloc(9 * 4800 * sizeof(int8_t));
    memset(cls_s8, -128, 9 * 4800 * sizeof(int8_t));

    /* Scale 1 (stride 16): 20x60 = 1200 anchors */
    int8_t *box_s16 = (int8_t *)calloc(4 * 1200, sizeof(int8_t));
    int8_t *cls_s16 = (int8_t *)malloc(9 * 1200 * sizeof(int8_t));
    memset(cls_s16, -128, 9 * 1200 * sizeof(int8_t));

    /* Scale 2 (stride 32): 10x30 = 300 anchors */
    int8_t *box_s32 = (int8_t *)calloc(4 * 300, sizeof(int8_t));
    int8_t *cls_s32 = (int8_t *)malloc(9 * 300 * sizeof(int8_t));
    memset(cls_s32, -128, 9 * 300 * sizeof(int8_t));

    /* Anchor (col=0, row=0) on scale 0: stride=8, dist=(1,1,1,1) with zp=0, scale=1.0 */
    box_s8[0 * 4800 + 0] = 1; /* l */
    box_s8[1 * 4800 + 0] = 1; /* t */
    box_s8[2 * 4800 + 0] = 1; /* r */
    box_s8[3 * 4800 + 0] = 1; /* b */

    /* Non-zero class: cls 5, score 0.80f: (76 - (-128)) * (1/255) = 204/255 = 0.8000f */
    cls_s8[5 * 4800 + 0] = 76;

    npu_tensor_t tensors[9];
    memset(tensors, 0, sizeof(tensors));

    /* Scale 0 */
    tensors[0].data = box_s8;
    tensors[0].channel_stride = 4800;
    tensors[0].row_stride = 120;
    tensors[0].col_stride = 1;
    tensors[0].scale = 1.0f;
    tensors[0].zp = 0;
    tensors[0].n_channels = 4;

    tensors[1].data = cls_s8;
    tensors[1].channel_stride = 4800;
    tensors[1].row_stride = 120;
    tensors[1].col_stride = 1;
    tensors[1].scale = 1.0f / 255.0f;
    tensors[1].zp = -128;
    tensors[1].n_channels = 9;

    /* Scale 1 */
    tensors[3].data = box_s16;
    tensors[3].channel_stride = 1200;
    tensors[3].row_stride = 60;
    tensors[3].col_stride = 1;
    tensors[3].scale = 1.0f;
    tensors[3].zp = 0;
    tensors[3].n_channels = 4;

    tensors[4].data = cls_s16;
    tensors[4].channel_stride = 1200;
    tensors[4].row_stride = 60;
    tensors[4].col_stride = 1;
    tensors[4].scale = 1.0f / 255.0f;
    tensors[4].zp = -128;
    tensors[4].n_channels = 9;

    /* Scale 2 */
    tensors[6].data = box_s32;
    tensors[6].channel_stride = 300;
    tensors[6].row_stride = 30;
    tensors[6].col_stride = 1;
    tensors[6].scale = 1.0f;
    tensors[6].zp = 0;
    tensors[6].n_channels = 4;

    tensors[7].data = cls_s32;
    tensors[7].channel_stride = 300;
    tensors[7].row_stride = 30;
    tensors[7].col_stride = 1;
    tensors[7].scale = 1.0f / 255.0f;
    tensors[7].zp = -128;
    tensors[7].n_channels = 9;

    npu_post_config_t cfg;
    npu_post_config_init(&cfg);

    npu_det_t dets[10];
    int num_dets = npu_post_process_9tensors_int8(&cfg, tensors, dets, 10);

    TEST_CHECK(num_dets == 1, "INT8 4-ch: exactly 1 detection");
    if (num_dets > 0) {
        printf("  [INT8 4-ch] det: cls=%d, score=%.4f, box=[%.3f, %.3f, %.3f, %.3f]\n",
               dets[0].cls, dets[0].score, dets[0].x0, dets[0].y0, dets[0].x1, dets[0].y1);
        TEST_CHECK(dets[0].cls == 5, "INT8 4-ch: cls matches expected 5");
        TEST_CHECK(fabsf(dets[0].score - 0.80f) < 1e-4f, "INT8 4-ch: score matches 0.80 within 1e-4");
        TEST_CHECK(fabsf(dets[0].x0 - (-4.0f)) < 1e-3f, "INT8 4-ch: x0 == -4 within 1e-3");
        TEST_CHECK(fabsf(dets[0].y0 - (-4.0f)) < 1e-3f, "INT8 4-ch: y0 == -4 within 1e-3");
        TEST_CHECK(fabsf(dets[0].x1 - 12.0f) < 1e-3f, "INT8 4-ch: x1 == 12 within 1e-3");
        TEST_CHECK(fabsf(dets[0].y1 - 12.0f) < 1e-3f, "INT8 4-ch: y1 == 12 within 1e-3");
    }

    /* Verify n_channels = 64 branches to DFL */
    tensors[0].n_channels = 64;
    npu_det_t dets_64[10];
    int num_dets_64 = npu_post_process_9tensors_int8(&cfg, tensors, dets_64, 10);
    TEST_CHECK(num_dets_64 == 1, "INT8 64-ch: exactly 1 detection");
    if (num_dets_64 > 0) {
        TEST_CHECK(fabsf(dets_64[0].x0 - (-4.0f)) > 1.0f, "INT8 64-ch: executes DFL instead of direct decode");
    }

    free(box_s8);
    free(cls_s8);
    free(box_s16);
    free(cls_s16);
    free(box_s32);
    free(cls_s32);
}

int main(void) {
    printf("=== NPU Post Units Test ===\n");
    test_map_to_src();
    test_pack_box_regs();
    test_format_npu_line();
    test_quant_threshold();
    test_sum_filter_margin();
    test_4ch_direct_fp32();
    test_4ch_direct_int8();

    if (g_failed == 0) {
        printf("ALL UNIT TESTS PASSED!\n");
        return 0;
    } else {
        printf("UNIT TESTS FAILED: %d errors\n", g_failed);
        return 1;
    }
}
