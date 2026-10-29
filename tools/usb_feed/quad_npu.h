#ifndef QUAD_NPU_H
#define QUAD_NPU_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "quad_sched.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *model_path;  /* Path to RKNN model, e.g. models/npu/b5_v6n_band.rknn */
    int weights[4];          /* SWRR weights, default {2, 1, 1, 1} if all 0 */
    float conf_thres;        /* Detection confidence threshold, default 0.25f */
    int dump_n;              /* Number of frames to dump per channel, 0 = disable */
    const char *dump_dir;    /* Dump directory, default "/tmp/qnpu_dump" */
} QnpuCfg;

typedef struct {
    uint32_t handle;         /* RGA buffer handle (0 if not imported) */
    int fd;                  /* DMA-buf fd (used if handle == 0) */
    int width;
    int height;
    int wstride;             /* Horizontal stride (pixels) */
    int hstride;             /* Vertical stride (lines) */
    int format;              /* Format, default RK_FORMAT_YCbCr_420_SP (NV12) */
    uint64_t frame_id;
} QnpuSrc;

/* Initialize NPU module: load model, allocate dual DMA input buffers,
 * configure output zero-copy, set OSD_CTRL |= 0x30, and start NPU thread.
 */
int qnpu_init(const QnpuCfg *cfg, volatile uint32_t *bar1);

/* Register that channel ch has a video source with dimensions src_w x src_h.
 * Enables channel in SWRR scheduling and configures band crop rectangle.
 */
void qnpu_register(int ch, int src_w, int src_h);

/* Offer a new frame from feed thread for channel ch.
 * If not nominated, returns immediately O(1) without locking.
 * If nominated, acquires request lock, verifies nomination, crops with RGA into
 * target buffer, records frame info, and signals NPU thread.
 */
void qnpu_offer(int ch, const QnpuSrc *src);

/* Format human-readable statistics line:
 * total fps, per-channel fps, run_avg, bind_avg, wait_avg, timeout counts.
 */
void qnpu_stats_line(char *buf, size_t n);

/* Stop NPU thread, clear all 16 OSD boxes and text line in BAR1, and release resources. */
void qnpu_stop(void);

/* Direct test inference helper for qnpu_selftest:
 * Copies rgb_data (960x320 RGB888, 921600 bytes) into input buffer, runs inference,
 * performs INT8 post-processing, and maps coordinates to channel ch screen space.
 */
int qnpu_direct_infer(const void *rgb_data, int ch,
                      npu_det_t *band_dets, npu_det_t *screen_dets,
                      int *num_dets, double *run_ms);

#ifdef __cplusplus
}
#endif

#endif /* QUAD_NPU_H */
