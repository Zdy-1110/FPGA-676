#ifndef QUAD_SCHED_H
#define QUAD_SCHED_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "npu_post.h"

#ifdef __cplusplus
extern "C" {
#endif

/* --- SWRR (Smooth Weighted Round-Robin, Nginx style) --- */
typedef struct {
    int weights[4];
    int current_weights[4];
    uint32_t valid_mask; /* bit 0..3: channel active & registered */
} quad_swrr_t;

void quad_swrr_init(quad_swrr_t *swrr, const int weights[4], uint32_t valid_mask);
void quad_swrr_set_mask(quad_swrr_t *swrr, uint32_t valid_mask);
int quad_swrr_next(quad_swrr_t *swrr);

/* --- Band Geometry --- */
typedef struct {
    int x;
    int y;
    int w;
    int h;
} quad_rect_t;

/* Crop band: (0, band_y, src_w, band_h) -> 960x320
 * band_y = (src_h / 3) & ~1
 * band_h = (src_h * 16 / 27) & ~1
 */
void quad_calc_band_rect(int src_w, int src_h, quad_rect_t *rect);

/* --- Coordinate Mapping --- */
/* Slot origin:
 * ch0: (0, 0),     ch1: (960, 0)
 * ch2: (0, 540),   ch3: (960, 540)
 */
void quad_slot_origin(int ch, int *ox, int *oy);

/* Screen coordinate conversion:
 * screen_x = clamp(round(bx + ox), ox, ox + 959)
 * screen_y = clamp(round(by + 180 + oy), oy, oy + 539)
 */
void quad_band_to_screen_box(int ch, float bx0, float by0, float bx1, float by1,
                             int32_t *sx0, int32_t *sy0, int32_t *sx1, int32_t *sy1);

void quad_band_to_screen_det(int ch, const npu_det_t *band_det, npu_det_t *screen_det);

void quad_set_fullscreen(int on);
int quad_is_fullscreen(void);

/* --- Box Selection --- */
/* Filter score >= conf_thres, sort by score desc, same score by original index asc.
 * Select up to top 4. Returns number of selected boxes (0..4).
 */
int quad_select_top4(const npu_det_t *dets, int num_dets, float conf_thres, npu_det_t top4[4]);

/* --- Register Packing & OSD Diff Cache --- */
typedef struct {
    uint32_t offset; /* byte offset from BAR1: 0x900 .. 0x97C */
    uint32_t val;
} quad_reg_write_t;

typedef struct {
    uint32_t shadow[32]; /* 32 DWs corresponding to 16 boxes in 0x900..0x97F */
} quad_osd_cache_t;

void quad_osd_cache_init(quad_osd_cache_t *cache);

/* Pack single box into DW0 and DW1 matching npu_pack_box_regs format:
 * DW0 = {color[31:28], y0[27:16], 0[15:12], x0[11:0]}
 * DW1 = {0[31:28],     y1[27:16], 0[15:12], x1[11:0]}
 */
void quad_pack_single_box(const npu_det_t *det, uint32_t *dw0, uint32_t *dw1);

/* Pack up to 4 boxes for channel ch into 8 DWs:
 * k = 0..3: regs[2*k + 0] = DW0, regs[2*k + 1] = DW1
 * Slots beyond count are set to 0.
 */
void quad_pack_ch_regs(const npu_det_t top4[4], int count, uint32_t regs[8]);

/* Compute diff between new_regs[8] and shadow cache for channel ch.
 * Writes changed words into out_writes (max_writes typically >= 8).
 * Enforces order: for each box, HIGH word is emitted before LOW word.
 * Updates shadow cache for emitted words.
 * Returns number of writes emitted.
 */
int quad_sched_diff_ch_regs(quad_osd_cache_t *cache, int ch, const uint32_t new_regs[8],
                            quad_reg_write_t *out_writes, int max_writes);

/* Timeout clear for channel ch:
 * Produces writes setting the 4 low DWs of channel ch to 0.
 * Updates shadow cache low words to 0.
 * Returns number of writes emitted (typically 4).
 */
int quad_sched_timeout_clear_ch(quad_osd_cache_t *cache, int ch,
                                quad_reg_write_t *out_writes, int max_writes);

#ifdef __cplusplus
}
#endif

#endif /* QUAD_SCHED_H */
