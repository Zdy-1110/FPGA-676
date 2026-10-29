#ifndef NPU_POST_H
#define NPU_POST_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NPU_NUM_CLASSES 9
#define NPU_MAX_REGS_BOXES 16

#define NPU_DEFAULT_CONF_THRES 0.25f
#define NPU_DEFAULT_IOU_THRES  0.60f
#define NPU_DEFAULT_MAX_CAND   1000
#define NPU_DEFAULT_MAX_DET    300

/* NMS Modes */
typedef enum {
    NPU_NMS_AGNOSTIC = 0,
    NPU_NMS_CLASS    = 1,
    NPU_NMS_PR_SPLIT = 2,
} npu_nms_mode_e;

/* Post-processing configuration */
typedef struct {
    float conf_thres;      /* default 0.25f */
    float iou_thres;       /* default 0.6f */
    int max_cand;          /* default 1000 */
    int max_det;           /* default 300 (eval) or 16 (display) */
    npu_nms_mode_e mode;   /* default NPU_NMS_PR_SPLIT */
} npu_post_config_t;

/* Detection result in 960x320 road-band coordinates */
typedef struct {
    int cls;
    float score;
    float x0;
    float y0;
    float x1;
    float y1;
} npu_det_t;

/* Layout & quantization description for 1 tensor buffer */
typedef struct {
    const void *data;        /* int8_t* or float* */
    int32_t zp;              /* zero point, for INT8 */
    float scale;             /* scale factor, for INT8 */
    int32_t channel_stride;  /* elements between channel c and c+1 */
    int32_t row_stride;      /* elements between row y and y+1 */
    int32_t col_stride;      /* elements between column x and x+1 (default 1) */
    int32_t n_channels;      /* 输出通道数：64=DFL，4=直接 LTRB */
} npu_tensor_t;

/* Tensors for 1 scale */
typedef struct {
    int stride;              /* 8, 16, or 32 */
    int h;                   /* 40, 20, or 10 */
    int w;                   /* 120, 60, or 30 */
    npu_tensor_t box;        /* 64 channels (4 * 16 DFL bins) */
    npu_tensor_t cls;        /* 9 channels (classes 0..8) */
    npu_tensor_t sum;        /* 1 channel */
} npu_scale_t;

/* Initialize default configuration (conf=0.25, iou=0.6, max_cand=1000, max_det=300, mode=pr_split) */
void npu_post_config_init(npu_post_config_t *cfg);

/* Core post-processing for FP32 tensors across 3 scales.
 * Returns number of output detections (<= max_out_dets).
 */
int npu_post_process_fp32(const npu_post_config_t *cfg,
                          const npu_scale_t scales[3],
                          npu_det_t *out_dets,
                          int max_out_dets);

/* Core post-processing for INT8 tensors across 3 scales.
 * Returns number of output detections (<= max_out_dets).
 */
int npu_post_process_int8(const npu_post_config_t *cfg,
                          const npu_scale_t scales[3],
                          npu_det_t *out_dets,
                          int max_out_dets);

/* Convenience wrapper: 9 tensors in canonical order:
 * [box_s8, cls_s8, sum_s8, box_s16, cls_s16, sum_s16, box_s32, cls_s32, sum_s32]
 */
int npu_post_process_9tensors_fp32(const npu_post_config_t *cfg,
                                   const npu_tensor_t tensors[9],
                                   npu_det_t *out_dets,
                                   int max_out_dets);

int npu_post_process_9tensors_int8(const npu_post_config_t *cfg,
                                   const npu_tensor_t tensors[9],
                                   npu_det_t *out_dets,
                                   int max_out_dets);

/* Map road-band box [0..960]x[0..320] to original image [0..1919]x[0..1079] with clamping:
 * sx = clamp(bx * 2, 0, 1919), sy = clamp(by * 2 + 360, 0, 1079).
 */
void npu_map_to_src(float bx0, float by0, float bx1, float by1,
                    float *sx0, float *sy0, float *sx1, float *sy1);

/* Map an array of detections from road-band to original image (in-place if band_dets == src_dets) */
void npu_map_dets_to_src(const npu_det_t *band_dets, npu_det_t *src_dets, int num_dets);

/* Map class index (0..8) to 3-bit FPGA display color:
 * 0 (person) -> 3 (yellow)
 * 1 (rider)  -> 6 (magenta)
 * 2 (car)    -> 5 (cyan)
 * 3 (bus)    -> 5 (cyan)
 * 4 (truck)  -> 5 (cyan)
 * 5 (tricycle)-> 4 (blue)
 * 6 (cone)   -> 7 (white)
 * 7 (barrier)-> 7 (white)
 * 8 (speed_limit) -> 2 (green)
 * other      -> 0 (no box)
 */
uint8_t npu_class_to_color(int cls);

/* Pack up to 16 detections into 32 DW registers (0x900..0x97F).
 * dets coordinates should be in original image pixels [0..1919]x[0..1079] (e.g. after map_to_src).
 * DW0 = {color[31:28], y0[27:16], 4'b0, x0[11:0]}
 * DW1 = {4'b0, y1[27:16], 4'b0, x1[11:0]}
 * Unused slots have color=0 (DW0=0, DW1=0).
 */
void npu_pack_box_regs(const npu_det_t *dets, int num_dets, uint32_t regs[32]);

/* Format 64-byte ASCII text line for text RAM row 2 (0xC80..0xCBF):
 * "NPU xx fps yy ms n=zz", remaining bytes padded with ' ' (0x20).
 */
void npu_format_npu_line(char out_line[64], int fps, int ms, int n);

/* Helper to convert float conf_thres to INT8 quantized threshold:
 * q_thr = ceil(conf / scale + zp), clamped to [-128, 127].
 */
int8_t npu_quant_conf_threshold(float conf, float scale, int32_t zp);

#ifdef __cplusplus
}
#endif

#endif /* NPU_POST_H */
