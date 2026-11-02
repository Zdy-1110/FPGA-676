#ifndef FCAM_RB_LIB_H
#define FCAM_RB_LIB_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define FCAM_FRAME_W         960u
#define FCAM_FRAME_H         540u
#define FCAM_BYTES_PER_PX    2u
#define FCAM_FRAME_BYTES     (FCAM_FRAME_W * FCAM_FRAME_H * FCAM_BYTES_PER_PX) /* 1,036,800 B */

typedef struct {
    volatile uint32_t *bar1;
    uint32_t fb_base;
    int dma_fd;
    size_t dma_len;
    void *dma_va;
    uint64_t dma_pa;
    uint32_t rga_handle;     /* pre-imported RGA buffer handle */
    uint32_t last_fid;
    int timeout_count;
} FcamRb;

/* Initialize front camera readback context: alloc CMA, check PA, import RGA handle */
int fcam_rb_init(FcamRb *fcam, volatile uint32_t *bar1);

/* Attempt to capture the latest complete frame.
 * Returns:
 *   1  : New frame captured successfully (DMA_BUF_SYNC_START already called)
 *   0  : No new frame (frame_id unchanged), skipped
 *  <0  : Hardware timeout or link error
 */
int fcam_rb_capture(FcamRb *fcam, int *out_buf_idx, uint32_t *out_fid, uint64_t *out_dur_us);

/* Call after processing frame to finish CPU DMA buffer sync */
void fcam_rb_sync_end(FcamRb *fcam);

/* Release resources: RGA handle, CMA buffer */
void fcam_rb_close(FcamRb *fcam);

/* Dump hardware diagnostic registers (0x1C0 - 0x1EC and cam status) */
void fcam_rb_dump_status(volatile uint32_t *bar1);

#endif /* FCAM_RB_LIB_H */
