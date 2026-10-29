#ifndef ADAS_H
#define ADAS_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "quad_npu.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Initialize ADAS module: tl params (roi_y_max_frac=1.0), allocate 1 CMA BGR buffer,
 * create ADAS thread.
 * Returns 0 on success, -1 on failure (e.g. CMA alloc failed).
 */
int adas_init(volatile uint32_t *bar1, const char *cfg_path);

/* Offer a frame from feed thread: only ch == 0 is processed.
 * Uses RGA to crop (0, 0, 1920, 648) and convert NV12 to BGR888 into DMA buffer.
 * If ADAS worker is busy processing previous frame, this offer is dropped immediately.
 */
void adas_offer(int ch, const QnpuSrc *src);

/* Stop ADAS thread and free resources */
void adas_stop(void);

/* Format ADAS status line for logging */
void adas_stats_line(char *buf, size_t max_len);

#ifdef __cplusplus
}
#endif

#endif /* ADAS_H */
