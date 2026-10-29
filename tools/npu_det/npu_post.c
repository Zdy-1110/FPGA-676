#include "npu_post.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

void npu_post_config_init(npu_post_config_t *cfg) {
    if (!cfg) return;
    cfg->conf_thres = NPU_DEFAULT_CONF_THRES;
    cfg->iou_thres = NPU_DEFAULT_IOU_THRES;
    cfg->max_cand = NPU_DEFAULT_MAX_CAND;
    cfg->max_det = NPU_DEFAULT_MAX_DET;
    cfg->mode = NPU_NMS_PR_SPLIT;
}

int8_t npu_quant_conf_threshold(float conf, float scale, int32_t zp) {
    if (scale <= 0.0f) return 127;
    float val = floorf(conf / scale + (float)zp) - 1.0f;
    if (val < -128.0f) return -128;
    if (val > 127.0f) return 127;
    return (int8_t)val;
}

uint8_t npu_class_to_color(int cls) {
    static const uint8_t colors[9] = {
        3, /* 0: person (yellow) */
        6, /* 1: rider (magenta) */
        5, /* 2: car (cyan) */
        5, /* 3: bus (cyan) */
        5, /* 4: truck (cyan) */
        4, /* 5: tricycle (blue) */
        7, /* 6: cone (white) */
        7, /* 7: barrier (white) */
        2  /* 8: speed_limit (green) */
    };
    if (cls >= 0 && cls < 9) {
        return colors[cls];
    }
    return 0;
}

void npu_map_to_src(float bx0, float by0, float bx1, float by1,
                    float *sx0, float *sy0, float *sx1, float *sy1) {
    float x0 = bx0 * 2.0f;
    float y0 = by0 * 2.0f + 360.0f;
    float x1 = bx1 * 2.0f;
    float y1 = by1 * 2.0f + 360.0f;

    if (x0 < 0.0f) x0 = 0.0f;
    else if (x0 > 1919.0f) x0 = 1919.0f;

    if (y0 < 0.0f) y0 = 0.0f;
    else if (y0 > 1079.0f) y0 = 1079.0f;

    if (x1 < 0.0f) x1 = 0.0f;
    else if (x1 > 1919.0f) x1 = 1919.0f;

    if (y1 < 0.0f) y1 = 0.0f;
    else if (y1 > 1079.0f) y1 = 1079.0f;

    if (sx0) *sx0 = x0;
    if (sy0) *sy0 = y0;
    if (sx1) *sx1 = x1;
    if (sy1) *sy1 = y1;
}

void npu_map_dets_to_src(const npu_det_t *band_dets, npu_det_t *src_dets, int num_dets) {
    if (!band_dets || !src_dets || num_dets <= 0) return;
    for (int i = 0; i < num_dets; ++i) {
        src_dets[i].cls = band_dets[i].cls;
        src_dets[i].score = band_dets[i].score;
        npu_map_to_src(band_dets[i].x0, band_dets[i].y0,
                       band_dets[i].x1, band_dets[i].y1,
                       &src_dets[i].x0, &src_dets[i].y0,
                       &src_dets[i].x1, &src_dets[i].y1);
    }
}

typedef struct {
    npu_det_t det;
    int orig_idx;
} reg_det_item_t;

static int reg_det_cmp_desc(const void *pa, const void *pb) {
    const reg_det_item_t *a = (const reg_det_item_t *)pa;
    const reg_det_item_t *b = (const reg_det_item_t *)pb;
    if (a->det.score > b->det.score) return -1;
    if (a->det.score < b->det.score) return 1;
    return (a->orig_idx < b->orig_idx) ? -1 : (a->orig_idx > b->orig_idx ? 1 : 0);
}

void npu_pack_box_regs(const npu_det_t *dets, int num_dets, uint32_t regs[32]) {
    if (!regs) return;
    for (int i = 0; i < 32; ++i) {
        regs[i] = 0;
    }
    if (!dets || num_dets <= 0) return;

    int n = num_dets;
    reg_det_item_t items[16];
    int count = 0;
    if (n <= 16) {
        for (int i = 0; i < n; ++i) {
            items[i].det = dets[i];
            items[i].orig_idx = i;
        }
        qsort(items, (size_t)n, sizeof(reg_det_item_t), reg_det_cmp_desc);
        count = n;
    } else {
        reg_det_item_t *all_items = (reg_det_item_t *)malloc(sizeof(reg_det_item_t) * (size_t)n);
        if (!all_items) return;
        for (int i = 0; i < n; ++i) {
            all_items[i].det = dets[i];
            all_items[i].orig_idx = i;
        }
        qsort(all_items, (size_t)n, sizeof(reg_det_item_t), reg_det_cmp_desc);
        for (int i = 0; i < 16; ++i) {
            items[i] = all_items[i];
        }
        free(all_items);
        count = 16;
    }

    for (int i = 0; i < count; ++i) {
        uint8_t color = npu_class_to_color(items[i].det.cls);
        int32_t ix0 = (int32_t)roundf(items[i].det.x0);
        int32_t iy0 = (int32_t)roundf(items[i].det.y0);
        int32_t ix1 = (int32_t)roundf(items[i].det.x1);
        int32_t iy1 = (int32_t)roundf(items[i].det.y1);

        if (ix0 < 0) ix0 = 0; else if (ix0 > 1919) ix0 = 1919;
        if (iy0 < 0) iy0 = 0; else if (iy0 > 1079) iy0 = 1079;
        if (ix1 < 0) ix1 = 0; else if (ix1 > 1919) ix1 = 1919;
        if (iy1 < 0) iy1 = 0; else if (iy1 > 1079) iy1 = 1079;

        uint32_t dw0 = ((uint32_t)(color & 0x0F) << 28) |
                       (((uint32_t)iy0 & 0x0FFF) << 16) |
                       ((uint32_t)ix0 & 0x0FFF);
        uint32_t dw1 = (((uint32_t)iy1 & 0x0FFF) << 16) |
                       ((uint32_t)ix1 & 0x0FFF);

        regs[2 * i + 0] = dw0;
        regs[2 * i + 1] = dw1;
    }
}

void npu_format_npu_line(char out_line[64], int fps, int ms, int n) {
    if (!out_line) return;
    int len = snprintf(out_line, 64, "NPU %d fps %d ms n=%d", fps, ms, n);
    if (len < 0) len = 0;
    if (len > 64) len = 64;
    memset(out_line + len, ' ', (size_t)(64 - len));
}

static inline float compute_iou(const npu_det_t *a, const npu_det_t *b) {
    float x1 = fmaxf(a->x0, b->x0);
    float y1 = fmaxf(a->y0, b->y0);
    float x2 = fminf(a->x1, b->x1);
    float y2 = fminf(a->y1, b->y1);
    float iw = fmaxf(x2 - x1, 0.0f);
    float ih = fmaxf(y2 - y1, 0.0f);
    float inter = iw * ih;
    float area_a = fmaxf(a->x1 - a->x0, 0.0f) * fmaxf(a->y1 - a->y0, 0.0f);
    float area_b = fmaxf(b->x1 - b->x0, 0.0f) * fmaxf(b->y1 - b->y0, 0.0f);
    float union_area = area_a + area_b - inter;
    if (union_area <= 0.0f) return 0.0f;
    return inter / union_area;
}

typedef struct {
    npu_det_t det;
    int orig_idx;
} cand_item_t;

static int cand_item_cmp_desc(const void *pa, const void *pb) {
    const cand_item_t *a = (const cand_item_t *)pa;
    const cand_item_t *b = (const cand_item_t *)pb;
    if (a->det.score > b->det.score) return -1;
    if (a->det.score < b->det.score) return 1;
    return (a->orig_idx < b->orig_idx) ? -1 : (a->orig_idx > b->orig_idx ? 1 : 0);
}

static void decode_dfl_fp32(const float *box_ptr,
                            int32_t channel_stride,
                            int32_t row_offset,
                            int32_t col_offset,
                            int col, int row, int stride,
                            float *x0, float *y0, float *x1, float *y1) {
    float dist[4];
    for (int e = 0; e < 4; ++e) {
        int base_ch = e * 16;
        float logit[16];
        float max_v = -1e30f;
        for (int k = 0; k < 16; ++k) {
            float v = box_ptr[(base_ch + k) * channel_stride + row_offset + col_offset];
            logit[k] = v;
            if (v > max_v) max_v = v;
        }
        float sum_exp = 0.0f;
        float exp_v[16];
        for (int k = 0; k < 16; ++k) {
            float ev = expf(logit[k] - max_v);
            exp_v[k] = ev;
            sum_exp += ev;
        }
        float inv_sum = 1.0f / sum_exp;
        float d = 0.0f;
        for (int k = 0; k < 16; ++k) {
            d += (float)k * (exp_v[k] * inv_sum);
        }
        dist[e] = d;
    }
    float ax = (float)col + 0.5f;
    float ay = (float)row + 0.5f;
    *x0 = (ax - dist[0]) * (float)stride;
    *y0 = (ay - dist[1]) * (float)stride;
    *x1 = (ax + dist[2]) * (float)stride;
    *y1 = (ay + dist[3]) * (float)stride;
}

static void decode_direct_fp32(const float *box_ptr,
                               int32_t channel_stride,
                               int32_t row_offset,
                               int32_t col_offset,
                               int col, int row, int stride,
                               float *x0, float *y0, float *x1, float *y1) {
    float dist[4];
    for (int e = 0; e < 4; ++e) {
        dist[e] = box_ptr[e * channel_stride + row_offset + col_offset];
    }
    float ax = (float)col + 0.5f;
    float ay = (float)row + 0.5f;
    *x0 = (ax - dist[0]) * (float)stride;
    *y0 = (ay - dist[1]) * (float)stride;
    *x1 = (ax + dist[2]) * (float)stride;
    *y1 = (ay + dist[3]) * (float)stride;
}

static void decode_dfl_int8(const int8_t *box_ptr,
                            int32_t channel_stride,
                            int32_t row_offset,
                            int32_t col_offset,
                            int32_t zp, float scale,
                            int col, int row, int stride,
                            float *x0, float *y0, float *x1, float *y1) {
    float dist[4];
    for (int e = 0; e < 4; ++e) {
        int base_ch = e * 16;
        float logit[16];
        float max_v = -1e30f;
        for (int k = 0; k < 16; ++k) {
            int8_t q = box_ptr[(base_ch + k) * channel_stride + row_offset + col_offset];
            float v = (float)(q - zp) * scale;
            logit[k] = v;
            if (v > max_v) max_v = v;
        }
        float sum_exp = 0.0f;
        float exp_v[16];
        for (int k = 0; k < 16; ++k) {
            float ev = expf(logit[k] - max_v);
            exp_v[k] = ev;
            sum_exp += ev;
        }
        float inv_sum = 1.0f / sum_exp;
        float d = 0.0f;
        for (int k = 0; k < 16; ++k) {
            d += (float)k * (exp_v[k] * inv_sum);
        }
        dist[e] = d;
    }
    float ax = (float)col + 0.5f;
    float ay = (float)row + 0.5f;
    *x0 = (ax - dist[0]) * (float)stride;
    *y0 = (ay - dist[1]) * (float)stride;
    *x1 = (ax + dist[2]) * (float)stride;
    *y1 = (ay + dist[3]) * (float)stride;
}

static void decode_direct_int8(const int8_t *box_ptr,
                               int32_t channel_stride,
                               int32_t row_offset,
                               int32_t col_offset,
                               int32_t zp, float scale,
                               int col, int row, int stride,
                               float *x0, float *y0, float *x1, float *y1) {
    float dist[4];
    for (int e = 0; e < 4; ++e) {
        int8_t q = box_ptr[e * channel_stride + row_offset + col_offset];
        dist[e] = (float)(q - zp) * scale;
    }
    float ax = (float)col + 0.5f;
    float ay = (float)row + 0.5f;
    *x0 = (ax - dist[0]) * (float)stride;
    *y0 = (ay - dist[1]) * (float)stride;
    *x1 = (ax + dist[2]) * (float)stride;
    *y1 = (ay + dist[3]) * (float)stride;
}

static int run_nms(cand_item_t *cands, int num_cands,
                   const npu_post_config_t *cfg,
                   npu_det_t *out_dets, int max_out_dets) {
    if (num_cands <= 0) return 0;

    int max_det = cfg ? cfg->max_det : NPU_DEFAULT_MAX_DET;
    float iou_thres = cfg ? cfg->iou_thres : NPU_DEFAULT_IOU_THRES;
    npu_nms_mode_e mode = cfg ? cfg->mode : NPU_NMS_PR_SPLIT;

    qsort(cands, (size_t)num_cands, sizeof(cand_item_t), cand_item_cmp_desc);

    uint8_t *suppressed = (uint8_t *)calloc((size_t)num_cands, sizeof(uint8_t));
    if (!suppressed) return 0;

    if (mode == NPU_NMS_AGNOSTIC) {
        for (int i = 0; i < num_cands; ++i) {
            if (suppressed[i]) continue;
            for (int j = i + 1; j < num_cands; ++j) {
                if (!suppressed[j]) {
                    if (compute_iou(&cands[i].det, &cands[j].det) > iou_thres) {
                        suppressed[j] = 1;
                    }
                }
            }
        }
    } else if (mode == NPU_NMS_CLASS) {
        for (int i = 0; i < num_cands; ++i) {
            if (suppressed[i]) continue;
            for (int j = i + 1; j < num_cands; ++j) {
                if (!suppressed[j] && cands[j].det.cls == cands[i].det.cls) {
                    if (compute_iou(&cands[i].det, &cands[j].det) > iou_thres) {
                        suppressed[j] = 1;
                    }
                }
            }
        }
    } else if (mode == NPU_NMS_PR_SPLIT) {
        for (int i = 0; i < num_cands; ++i) {
            if (suppressed[i]) continue;
            int cls_i = cands[i].det.cls;
            for (int j = i + 1; j < num_cands; ++j) {
                if (!suppressed[j]) {
                    int cls_j = cands[j].det.cls;
                    bool is_pr_pair = ((cls_i == 0 && cls_j == 1) || (cls_i == 1 && cls_j == 0));
                    if (!is_pr_pair) {
                        if (compute_iou(&cands[i].det, &cands[j].det) > iou_thres) {
                            suppressed[j] = 1;
                        }
                    }
                }
            }
        }
    }

    int num_out = 0;
    for (int i = 0; i < num_cands && num_out < max_det && num_out < max_out_dets; ++i) {
        if (!suppressed[i]) {
            out_dets[num_out++] = cands[i].det;
        }
    }

    free(suppressed);
    return num_out;
}

int npu_post_process_fp32(const npu_post_config_t *cfg,
                          const npu_scale_t scales[3],
                          npu_det_t *out_dets,
                          int max_out_dets) {
    if (!scales || !out_dets || max_out_dets <= 0) return 0;

    float conf_thres = cfg ? cfg->conf_thres : NPU_DEFAULT_CONF_THRES;
    int max_cand = cfg ? cfg->max_cand : NPU_DEFAULT_MAX_CAND;
    if (max_cand <= 0) max_cand = NPU_DEFAULT_MAX_CAND;

    int total_anchors = 0;
    for (int s = 0; s < 3; ++s) {
        total_anchors += scales[s].h * scales[s].w;
    }

    cand_item_t *cands = (cand_item_t *)malloc(sizeof(cand_item_t) * (size_t)total_anchors);
    if (!cands) return 0;

    int num_cands = 0;
    int global_anchor_idx = 0;

    for (int s = 0; s < 3; ++s) {
        const npu_scale_t *sc = &scales[s];
        int stride = sc->stride;
        int h = sc->h;
        int w = sc->w;

        const float *box_ptr = (const float *)sc->box.data;
        const float *cls_ptr = (const float *)sc->cls.data;
        const float *sum_ptr = (const float *)sc->sum.data;

        int32_t box_ch_stride = sc->box.channel_stride;
        int32_t box_row_stride = sc->box.row_stride;
        int32_t box_col_stride = sc->box.col_stride ? sc->box.col_stride : 1;

        int32_t cls_ch_stride = sc->cls.channel_stride;
        int32_t cls_row_stride = sc->cls.row_stride;
        int32_t cls_col_stride = sc->cls.col_stride ? sc->cls.col_stride : 1;

        int32_t sum_row_stride = sc->sum.row_stride;
        int32_t sum_col_stride = sc->sum.col_stride ? sc->sum.col_stride : 1;

        float sum_filter_thres = conf_thres - (1.0f / 255.0f);
        if (sum_filter_thres < 0.0f) sum_filter_thres = 0.0f;

        for (int r = 0; r < h; ++r) {
            int32_t b_row = r * box_row_stride;
            int32_t c_row = r * cls_row_stride;
            int32_t s_row = r * sum_row_stride;

            for (int c = 0; c < w; ++c) {
                int anchor_idx = global_anchor_idx++;
                int32_t b_col = c * box_col_stride;
                int32_t c_col = c * cls_col_stride;
                int32_t s_col = c * sum_col_stride;

                if (sum_ptr) {
                    float sum_val = sum_ptr[s_row + s_col];
                    if (sum_val < sum_filter_thres) {
                        continue;
                    }
                }

                int best_cls = 0;
                float max_score = cls_ptr[0 * cls_ch_stride + c_row + c_col];
                for (int cl = 1; cl < NPU_NUM_CLASSES; ++cl) {
                    float sc_val = cls_ptr[cl * cls_ch_stride + c_row + c_col];
                    if (sc_val > max_score) {
                        max_score = sc_val;
                        best_cls = cl;
                    }
                }

                if (max_score < conf_thres) {
                    continue;
                }

                float x0, y0, x1, y1;
                if (sc->box.n_channels == 4)
                    decode_direct_fp32(box_ptr, box_ch_stride, b_row, b_col, c, r, stride, &x0, &y0, &x1, &y1);
                else
                    decode_dfl_fp32(box_ptr, box_ch_stride, b_row, b_col, c, r, stride, &x0, &y0, &x1, &y1);

                cands[num_cands].det.cls = best_cls;
                cands[num_cands].det.score = max_score;
                cands[num_cands].det.x0 = x0;
                cands[num_cands].det.y0 = y0;
                cands[num_cands].det.x1 = x1;
                cands[num_cands].det.y1 = y1;
                cands[num_cands].orig_idx = anchor_idx;
                num_cands++;
            }
        }
    }

    if (num_cands > max_cand) {
        qsort(cands, (size_t)num_cands, sizeof(cand_item_t), cand_item_cmp_desc);
        num_cands = max_cand;
    }

    int ret = run_nms(cands, num_cands, cfg, out_dets, max_out_dets);
    free(cands);
    return ret;
}

int npu_post_process_int8(const npu_post_config_t *cfg,
                          const npu_scale_t scales[3],
                          npu_det_t *out_dets,
                          int max_out_dets) {
    if (!scales || !out_dets || max_out_dets <= 0) return 0;

    float conf_thres = cfg ? cfg->conf_thres : NPU_DEFAULT_CONF_THRES;
    int max_cand = cfg ? cfg->max_cand : NPU_DEFAULT_MAX_CAND;
    if (max_cand <= 0) max_cand = NPU_DEFAULT_MAX_CAND;

    int total_anchors = 0;
    for (int s = 0; s < 3; ++s) {
        total_anchors += scales[s].h * scales[s].w;
    }

    cand_item_t *cands = (cand_item_t *)malloc(sizeof(cand_item_t) * (size_t)total_anchors);
    if (!cands) return 0;

    int num_cands = 0;
    int global_anchor_idx = 0;

    for (int s = 0; s < 3; ++s) {
        const npu_scale_t *sc = &scales[s];
        int stride = sc->stride;
        int h = sc->h;
        int w = sc->w;

        const int8_t *box_ptr = (const int8_t *)sc->box.data;
        const int8_t *cls_ptr = (const int8_t *)sc->cls.data;
        const int8_t *sum_ptr = (const int8_t *)sc->sum.data;

        int32_t box_ch_stride = sc->box.channel_stride;
        int32_t box_row_stride = sc->box.row_stride;
        int32_t box_col_stride = sc->box.col_stride ? sc->box.col_stride : 1;
        int32_t box_zp = sc->box.zp;
        float box_scale = sc->box.scale;

        int32_t cls_ch_stride = sc->cls.channel_stride;
        int32_t cls_row_stride = sc->cls.row_stride;
        int32_t cls_col_stride = sc->cls.col_stride ? sc->cls.col_stride : 1;
        int32_t cls_zp = sc->cls.zp;
        float cls_scale = sc->cls.scale;

        int32_t sum_row_stride = sc->sum.row_stride;
        int32_t sum_col_stride = sc->sum.col_stride ? sc->sum.col_stride : 1;

        int8_t sum_q_thr = -128;
        if (sum_ptr) {
            sum_q_thr = npu_quant_conf_threshold(conf_thres, sc->sum.scale, sc->sum.zp);
        }

        for (int r = 0; r < h; ++r) {
            int32_t b_row = r * box_row_stride;
            int32_t c_row = r * cls_row_stride;
            int32_t s_row = r * sum_row_stride;

            for (int c = 0; c < w; ++c) {
                int anchor_idx = global_anchor_idx++;
                int32_t b_col = c * box_col_stride;
                int32_t c_col = c * cls_col_stride;
                int32_t s_col = c * sum_col_stride;

                if (sum_ptr) {
                    int8_t sum_val = sum_ptr[s_row + s_col];
                    if (sum_val < sum_q_thr) {
                        continue;
                    }
                }

                int best_cls = 0;
                int8_t max_q = cls_ptr[0 * cls_ch_stride + c_row + c_col];
                for (int cl = 1; cl < NPU_NUM_CLASSES; ++cl) {
                    int8_t q_val = cls_ptr[cl * cls_ch_stride + c_row + c_col];
                    if (q_val > max_q) {
                        max_q = q_val;
                        best_cls = cl;
                    }
                }

                float max_score = (float)(max_q - cls_zp) * cls_scale;
                if (max_score < conf_thres) {
                    continue;
                }

                float x0, y0, x1, y1;
                if (sc->box.n_channels == 4)
                    decode_direct_int8(box_ptr, box_ch_stride, b_row, b_col, box_zp, box_scale, c, r, stride, &x0, &y0, &x1, &y1);
                else
                    decode_dfl_int8(box_ptr, box_ch_stride, b_row, b_col, box_zp, box_scale, c, r, stride, &x0, &y0, &x1, &y1);

                cands[num_cands].det.cls = best_cls;
                cands[num_cands].det.score = max_score;
                cands[num_cands].det.x0 = x0;
                cands[num_cands].det.y0 = y0;
                cands[num_cands].det.x1 = x1;
                cands[num_cands].det.y1 = y1;
                cands[num_cands].orig_idx = anchor_idx;
                num_cands++;
            }
        }
    }

    if (num_cands > max_cand) {
        qsort(cands, (size_t)num_cands, sizeof(cand_item_t), cand_item_cmp_desc);
        num_cands = max_cand;
    }

    int ret = run_nms(cands, num_cands, cfg, out_dets, max_out_dets);
    free(cands);
    return ret;
}

int npu_post_process_9tensors_fp32(const npu_post_config_t *cfg,
                                   const npu_tensor_t tensors[9],
                                   npu_det_t *out_dets,
                                   int max_out_dets) {
    if (!tensors || !out_dets || max_out_dets <= 0) return 0;
    npu_scale_t scales[3];
    int strides[3] = {8, 16, 32};
    int hs[3] = {40, 20, 10};
    int ws[3] = {120, 60, 30};
    for (int s = 0; s < 3; ++s) {
        scales[s].stride = strides[s];
        scales[s].h = hs[s];
        scales[s].w = ws[s];
        scales[s].box = tensors[3 * s + 0];
        scales[s].cls = tensors[3 * s + 1];
        scales[s].sum = tensors[3 * s + 2];
    }
    return npu_post_process_fp32(cfg, scales, out_dets, max_out_dets);
}

int npu_post_process_9tensors_int8(const npu_post_config_t *cfg,
                                   const npu_tensor_t tensors[9],
                                   npu_det_t *out_dets,
                                   int max_out_dets) {
    if (!tensors || !out_dets || max_out_dets <= 0) return 0;
    npu_scale_t scales[3];
    int strides[3] = {8, 16, 32};
    int hs[3] = {40, 20, 10};
    int ws[3] = {120, 60, 30};
    for (int s = 0; s < 3; ++s) {
        scales[s].stride = strides[s];
        scales[s].h = hs[s];
        scales[s].w = ws[s];
        scales[s].box = tensors[3 * s + 0];
        scales[s].cls = tensors[3 * s + 1];
        scales[s].sum = tensors[3 * s + 2];
    }
    return npu_post_process_int8(cfg, scales, out_dets, max_out_dets);
}
