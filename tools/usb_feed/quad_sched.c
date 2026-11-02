#include "quad_sched.h"
#include <string.h>
#include <stdlib.h>
#include <math.h>

void quad_swrr_init(quad_swrr_t *swrr, const int weights[4], uint32_t valid_mask)
{
    if (!swrr) return;
    for (int i = 0; i < 4; i++) {
        swrr->weights[i] = weights ? weights[i] : 0;
        swrr->current_weights[i] = 0;
    }
    swrr->valid_mask = valid_mask & 0x0Fu;
}

void quad_swrr_set_mask(quad_swrr_t *swrr, uint32_t valid_mask)
{
    if (!swrr) return;
    swrr->valid_mask = valid_mask & 0x0Fu;
    for (int i = 0; i < 4; i++) {
        if (!(swrr->valid_mask & (1u << i))) {
            swrr->current_weights[i] = 0;
        }
    }
}

int quad_swrr_next(quad_swrr_t *swrr)
{
    if (!swrr) return -1;
    int best = -1;
    int total = 0;
    for (int i = 0; i < 4; i++) {
        if (!(swrr->valid_mask & (1u << i)) || swrr->weights[i] <= 0) {
            continue;
        }
        swrr->current_weights[i] += swrr->weights[i];
        total += swrr->weights[i];
        if (best < 0 || swrr->current_weights[i] > swrr->current_weights[best]) {
            best = i;
        }
    }
    if (best >= 0) {
        swrr->current_weights[best] -= total;
    }
    return best;
}

void quad_calc_band_rect(int src_w, int src_h, quad_rect_t *rect)
{
    if (!rect) return;
    rect->x = 0;
    rect->w = src_w;
    rect->y = (src_h / 3) & ~1;
    rect->h = ((src_h * 16) / 27) & ~1;
}

void quad_slot_origin(int ch, int *ox, int *oy)
{
    int x = (ch & 1) ? 960 : 0;
    int y = (ch >= 2) ? 540 : 0;
    if (ox) *ox = x;
    if (oy) *oy = y;
}

static inline int32_t clamp_i32(int32_t v, int32_t min_v, int32_t max_v)
{
    if (v < min_v) return min_v;
    if (v > max_v) return max_v;
    return v;
}

static int g_quad_fullscreen = 0;

void quad_set_fullscreen(int on)
{
    g_quad_fullscreen = on ? 1 : 0;
}

int quad_is_fullscreen(void)
{
    return g_quad_fullscreen;
}

void quad_band_to_screen_box(int ch, float bx0, float by0, float bx1, float by1,
                             int32_t *sx0, int32_t *sy0, int32_t *sx1, int32_t *sy1)
{
    if (g_quad_fullscreen) {
        int32_t x0 = (int32_t)roundf(bx0 * 2.0f);
        int32_t y0 = (int32_t)roundf(by0 * 2.0f + 360.0f);
        int32_t x1 = (int32_t)roundf(bx1 * 2.0f);
        int32_t y1 = (int32_t)roundf(by1 * 2.0f + 360.0f);

        if (sx0) *sx0 = clamp_i32(x0, 0, 1919);
        if (sy0) *sy0 = clamp_i32(y0, 0, 1079);
        if (sx1) *sx1 = clamp_i32(x1, 0, 1919);
        if (sy1) *sy1 = clamp_i32(y1, 0, 1079);
        return;
    }

    int ox = 0, oy = 0;
    quad_slot_origin(ch, &ox, &oy);

    int32_t x0 = (int32_t)roundf(bx0 + (float)ox);
    int32_t y0 = (int32_t)roundf(by0 + 180.0f + (float)oy);
    int32_t x1 = (int32_t)roundf(bx1 + (float)ox);
    int32_t y1 = (int32_t)roundf(by1 + 180.0f + (float)oy);

    if (sx0) *sx0 = clamp_i32(x0, ox, ox + 959);
    if (sy0) *sy0 = clamp_i32(y0, oy, oy + 539);
    if (sx1) *sx1 = clamp_i32(x1, ox, ox + 959);
    if (sy1) *sy1 = clamp_i32(y1, oy, oy + 539);
}

void quad_band_to_screen_det(int ch, const npu_det_t *band_det, npu_det_t *screen_det)
{
    if (!band_det || !screen_det) return;
    *screen_det = *band_det;
    int32_t sx0, sy0, sx1, sy1;
    quad_band_to_screen_box(ch, band_det->x0, band_det->y0, band_det->x1, band_det->y1,
                            &sx0, &sy0, &sx1, &sy1);
    screen_det->x0 = (float)sx0;
    screen_det->y0 = (float)sy0;
    screen_det->x1 = (float)sx1;
    screen_det->y1 = (float)sy1;
}

typedef struct {
    npu_det_t det;
    int orig_idx;
} quad_det_item_t;

static int det_cmp_score_desc(const void *a, const void *b)
{
    const quad_det_item_t *da = (const quad_det_item_t *)a;
    const quad_det_item_t *db = (const quad_det_item_t *)b;
    if (da->det.score > db->det.score) return -1;
    if (da->det.score < db->det.score) return 1;
    return (da->orig_idx < db->orig_idx) ? -1 : (da->orig_idx > db->orig_idx ? 1 : 0);
}

int quad_select_top4(const npu_det_t *dets, int num_dets, float conf_thres, npu_det_t top4[4])
{
    if (!top4) return 0;
    for (int i = 0; i < 4; i++) {
        memset(&top4[i], 0, sizeof(top4[i]));
        top4[i].cls = -1;
    }
    if (!dets || num_dets <= 0) return 0;

    quad_det_item_t filtered[300];
    int count = 0;
    for (int i = 0; i < num_dets && count < 300; i++) {
        if (dets[i].score >= conf_thres) {
            filtered[count].det = dets[i];
            filtered[count].orig_idx = i;
            count++;
        }
    }
    if (count == 0) return 0;

    qsort(filtered, (size_t)count, sizeof(quad_det_item_t), det_cmp_score_desc);

    int n = count < 4 ? count : 4;
    for (int i = 0; i < n; i++) {
        top4[i] = filtered[i].det;
    }
    return n;
}

void quad_pack_single_box(const npu_det_t *det, uint32_t *dw0, uint32_t *dw1)
{
    if (!dw0 || !dw1) return;
    *dw0 = 0;
    *dw1 = 0;
    if (!det || det->cls < 0) return;

    uint8_t color = npu_class_to_color(det->cls);
    if (color == 0) return;

    int32_t ix0 = (int32_t)roundf(det->x0);
    int32_t iy0 = (int32_t)roundf(det->y0);
    int32_t ix1 = (int32_t)roundf(det->x1);
    int32_t iy1 = (int32_t)roundf(det->y1);

    if (ix0 < 0) ix0 = 0; else if (ix0 > 1919) ix0 = 1919;
    if (iy0 < 0) iy0 = 0; else if (iy0 > 1079) iy0 = 1079;
    if (ix1 < 0) ix1 = 0; else if (ix1 > 1919) ix1 = 1919;
    if (iy1 < 0) iy1 = 0; else if (iy1 > 1079) iy1 = 1079;

    *dw0 = ((uint32_t)(color & 0x0Fu) << 28) |
           (((uint32_t)iy0 & 0x0FFFu) << 16) |
           ((uint32_t)ix0 & 0x0FFFu);
    *dw1 = (((uint32_t)iy1 & 0x0FFFu) << 16) |
           ((uint32_t)ix1 & 0x0FFFu);
}

void quad_pack_ch_regs(const npu_det_t top4[4], int count, uint32_t regs[8])
{
    if (!regs) return;
    for (int i = 0; i < 8; i++) regs[i] = 0;
    int n = count < 4 ? count : 4;
    for (int k = 0; k < n; k++) {
        quad_pack_single_box(&top4[k], &regs[2 * k + 0], &regs[2 * k + 1]);
    }
}

void quad_osd_cache_init(quad_osd_cache_t *cache)
{
    if (!cache) return;
    memset(cache->shadow, 0, sizeof(cache->shadow));
}

int quad_sched_diff_ch_regs(quad_osd_cache_t *cache, int ch, const uint32_t new_regs[8],
                            quad_reg_write_t *out_writes, int max_writes)
{
    if (!cache || !new_regs || !out_writes || ch < 0 || ch >= 4) return 0;
    int emitted = 0;
    for (int k = 0; k < 4; k++) {
        /* Enforce order: HIGH word before LOW word */
        int high_idx = ch * 8 + k * 2 + 1;
        uint32_t new_high = new_regs[k * 2 + 1];
        if (new_high != cache->shadow[high_idx]) {
            if (emitted < max_writes) {
                out_writes[emitted].offset = 0x900u + (uint32_t)(high_idx * 4);
                out_writes[emitted].val = new_high;
                emitted++;
            }
            cache->shadow[high_idx] = new_high;
        }

        int low_idx = ch * 8 + k * 2;
        uint32_t new_low = new_regs[k * 2];
        if (new_low != cache->shadow[low_idx]) {
            if (emitted < max_writes) {
                out_writes[emitted].offset = 0x900u + (uint32_t)(low_idx * 4);
                out_writes[emitted].val = new_low;
                emitted++;
            }
            cache->shadow[low_idx] = new_low;
        }
    }
    return emitted;
}

int quad_sched_timeout_clear_ch(quad_osd_cache_t *cache, int ch,
                                quad_reg_write_t *out_writes, int max_writes)
{
    if (!out_writes || ch < 0 || ch >= 4) return 0;
    int emitted = 0;
    for (int k = 0; k < 4; k++) {
        int low_idx = ch * 8 + k * 2;
        if (emitted < max_writes) {
            out_writes[emitted].offset = 0x900u + (uint32_t)((ch * 4 + k) * 8);
            out_writes[emitted].val = 0;
            emitted++;
        }
        if (cache) {
            cache->shadow[low_idx] = 0;
        }
    }
    return emitted;
}
