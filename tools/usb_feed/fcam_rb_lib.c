#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "im2d.h"
#include "RgaApi.h"
#include "fcam_rb_lib.h"

#if defined(__has_include) && __has_include(<linux/dma-heap.h>)
#include <linux/dma-heap.h>
#endif
#ifndef DMA_HEAP_IOCTL_ALLOC
struct dma_heap_allocation_data {
    uint64_t len;
    uint32_t fd;
    uint32_t fd_flags;
    uint64_t heap_flags;
};
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)
#endif

#if defined(__has_include) && __has_include(<linux/dma-buf.h>)
#include <linux/dma-buf.h>
#endif
#ifndef DMA_BUF_IOCTL_SYNC
struct dma_buf_sync {
    uint64_t flags;
};
#define DMA_BUF_SYNC_READ  (1 << 0)
#define DMA_BUF_SYNC_WRITE (2 << 0)
#define DMA_BUF_SYNC_RW    (DMA_BUF_SYNC_READ | DMA_BUF_SYNC_WRITE)
#define DMA_BUF_SYNC_START (0 << 2)
#define DMA_BUF_SYNC_END   (1 << 2)
#define DMA_BUF_BASE       'b'
#define DMA_BUF_IOCTL_SYNC _IOW(DMA_BUF_BASE, 0, struct dma_buf_sync)
#endif

#define DDR_RB_MAX_SEG      32768u
#define DDR_RAM_WORD_OFF    2048u
#define MWR_CHUNK_MAX       8192u
#define POLL_TIMEOUT_US     50000ULL

static inline uint32_t rd(volatile uint32_t *bar1, uint32_t byte_off)
{
    return bar1[byte_off >> 2];
}

static inline void wr(volatile uint32_t *bar1, uint32_t byte_off, uint32_t val)
{
    bar1[byte_off >> 2] = val;
}

static inline uint64_t now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

void fcam_rb_dump_status(volatile uint32_t *bar1)
{
    fprintf(stderr, "\n[fcam_rb_lib] Hub Status Registers (0x1C0 - 0x1EC):\n");
    for (uint32_t off = 0x1C0; off <= 0x1EC; off += 4) {
        fprintf(stderr, "  BAR1[0x%03X] = 0x%08X\n", off, rd(bar1, off));
    }
    fprintf(stderr, "  BAR1[0x804 FB_BASE] = 0x%08X\n", rd(bar1, 0x804));
    fprintf(stderr, "  BAR1[0x820 FB_STAT] = 0x%08X (fid=%u, slot=%u)\n",
            rd(bar1, 0x820), (rd(bar1, 0x820) >> 16) & 0xFFFFu, rd(bar1, 0x820) & 0x3u);
    fprintf(stderr, "  BAR1[0x8A0 CAM_STAT0] = 0x%08X\n", rd(bar1, 0x8A0));
    fprintf(stderr, "  BAR1[0x8A4 CAM_STAT1] = 0x%08X\n", rd(bar1, 0x8A4));
}

static int check_phys_range(void *va, size_t len, long ps, uint64_t *out_pa)
{
    int pfd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    if (pfd < 0) {
        perror("[fcam_rb_lib] open /proc/self/pagemap");
        return -1;
    }
    size_t npages = (len + (size_t)ps - 1) / (size_t)ps;
    uint64_t first = 0;

    for (size_t k = 0; k < npages; k++) {
        uint64_t e = 0;
        off_t off = (off_t)(((uintptr_t)va + k * (uint64_t)ps) / (uint64_t)ps) * 8;
        if (pread(pfd, &e, 8, off) != 8) {
            fprintf(stderr, "[fcam_rb_lib] pagemap read failed on page %zu\n", k);
            close(pfd);
            return -1;
        }
        uint64_t pfn = e & ((1ULL << 55) - 1);
        if (!(e & (1ULL << 63)) || pfn == 0) {
            fprintf(stderr, "[fcam_rb_lib] page %zu not present in RAM\n", k);
            close(pfd);
            return -1;
        }
        uint64_t pa = pfn * (uint64_t)ps;
        if (k == 0) {
            first = pa;
        } else if (pa != first + k * (uint64_t)ps) {
            fprintf(stderr, "[fcam_rb_lib] CMA memory not physically contiguous at page %zu\n", k);
            close(pfd);
            return -1;
        }
    }
    close(pfd);

    if (first + len > 0x100000000ULL) {
        fprintf(stderr, "[fcam_rb_lib] Physical address 0x%llx is above 4GB limit\n",
                (unsigned long long)(first + len));
        return -1;
    }
    if (out_pa) *out_pa = first;
    return 0;
}

int fcam_rb_init(FcamRb *fcam, volatile uint32_t *bar1)
{
    if (!fcam || !bar1) return -1;
    memset(fcam, 0, sizeof(*fcam));
    fcam->bar1 = bar1;
    fcam->dma_fd = -1;

    uint32_t base = rd(bar1, 0x804);
    fcam->fb_base = (base != 0) ? base : 0x04000000u;

    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) ps = 4096;

    int hfd = open("/dev/dma_heap/cma", O_RDWR | O_CLOEXEC);
    if (hfd < 0) {
        perror("[fcam_rb_lib] open /dev/dma_heap/cma");
        return -1;
    }

    struct dma_heap_allocation_data data;
    memset(&data, 0, sizeof(data));
    data.len = (FCAM_FRAME_BYTES + 4095u) & ~(uint64_t)4095u;
    data.fd_flags = O_RDWR | O_CLOEXEC;

    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) {
        perror("[fcam_rb_lib] ioctl DMA_HEAP_IOCTL_ALLOC");
        close(hfd);
        return -1;
    }
    close(hfd);

    fcam->dma_len = (size_t)data.len;
    fcam->dma_fd = (int)data.fd;
    fcam->dma_va = mmap(NULL, fcam->dma_len, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_POPULATE, fcam->dma_fd, 0);
    if (fcam->dma_va == MAP_FAILED) {
        perror("[fcam_rb_lib] mmap dma-heap");
        close(fcam->dma_fd);
        fcam->dma_fd = -1;
        return -1;
    }

    if (check_phys_range(fcam->dma_va, fcam->dma_len, ps, &fcam->dma_pa) < 0) {
        munmap(fcam->dma_va, fcam->dma_len);
        close(fcam->dma_fd);
        fcam->dma_fd = -1;
        fcam->dma_va = NULL;
        return -1;
    }

    /* Pre-import RGA buffer handle for zero-copy crop/convert */
    im_handle_param_t param;
    memset(&param, 0, sizeof(param));
    param.width = FCAM_FRAME_W;
    param.height = FCAM_FRAME_H;
    param.format = RK_FORMAT_RGB_565;
    rga_buffer_handle_t h = importbuffer_fd(fcam->dma_fd, &param);
    if (h > 0) {
        fcam->rga_handle = (uint32_t)h;
    } else {
        fcam->rga_handle = 0;
    }

    fcam->last_fid = (rd(bar1, 0x820) >> 16) & 0xFFFFu;
    return 0;
}

static inline void dmabuf_sync(int fd, int start)
{
    if (fd < 0) return;
    struct dma_buf_sync sync;
    memset(&sync, 0, sizeof(sync));
    sync.flags = DMA_BUF_SYNC_READ | (start ? DMA_BUF_SYNC_START : DMA_BUF_SYNC_END);
    if (ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync) < 0) {
        perror("[fcam_rb_lib] DMA_BUF_IOCTL_SYNC failed");
    }
}

void fcam_rb_sync_end(FcamRb *fcam)
{
    if (fcam && fcam->dma_fd >= 0) {
        dmabuf_sync(fcam->dma_fd, 0);
    }
}

int fcam_rb_capture(FcamRb *fcam, int *out_buf_idx, uint32_t *out_fid, uint64_t *out_dur_us)
{
    if (!fcam || !fcam->bar1 || fcam->dma_fd < 0) return -1;
    volatile uint32_t *bar1 = fcam->bar1;

    uint32_t cur_fid = (rd(bar1, 0x820) >> 16) & 0xFFFFu;
    if (cur_fid == fcam->last_fid) {
        return 0; /* No new frame */
    }

    int buf_idx = (int)(cur_fid & 1u);
    uint32_t ddr_addr = fcam->fb_base + (buf_idx ? 0x00100000u : 0u);

    uint64_t t0_start = now_us();
    uint32_t seg = 0;

    while (seg < FCAM_FRAME_BYTES) {
        uint32_t slen = FCAM_FRAME_BYTES - seg;
        if (slen > DDR_RB_MAX_SEG) slen = DDR_RB_MAX_SEG;

        /* Step 1: DDR -> FPGA RAM */
        wr(bar1, 0x1A8, ddr_addr + seg);
        wr(bar1, 0x1AC, slen);
        wr(bar1, 0x1B0, DDR_RAM_WORD_OFF);

        uint32_t old_done = rd(bar1, 0x1DC);
        wr(bar1, 0x1B4, 1);

        uint64_t t_poll = now_us();
        while (rd(bar1, 0x1DC) == old_done) {
            if (now_us() - t_poll >= POLL_TIMEOUT_US) {
                fprintf(stderr, "\n[fcam_rb_lib] Timeout on 0x1DC! seg=%u slen=%u\n", seg, slen);
                fcam_rb_dump_status(bar1);
                wr(bar1, 0x250, 0);
                wr(bar1, 0x210, 0);
                fcam->timeout_count++;
                return -2;
            }
        }

        /* Step 2: FPGA RAM -> Host CMA (MWr) */
        for (uint32_t chunk = 0; chunk < slen; chunk += MWR_CHUNK_MAX) {
            uint32_t clen = slen - chunk;
            if (clen > MWR_CHUNK_MAX) clen = MWR_CHUNK_MAX;

            wr(bar1, 0x210, (DDR_RAM_WORD_OFF + (chunk >> 4)) * 8u);
            wr(bar1, 0x200, (uint32_t)(fcam->dma_pa + seg + chunk));
            wr(bar1, 0x204, 0);
            wr(bar1, 0x220, 1023);
            wr(bar1, 0x250, clen >> 2);
            wr(bar1, 0x240, 0);

            t_poll = now_us();
            for (;;) {
                uint32_t v = rd(bar1, 0x230);
                if (v == 0xFFFFFFFFu) {
                    fprintf(stderr, "\n[fcam_rb_lib] PCIe link down (0x230 == 0xFFFFFFFF)!\n");
                    fcam->timeout_count++;
                    return -3;
                }
                if (v != 0) break;
                if (now_us() - t_poll >= POLL_TIMEOUT_US) {
                    fprintf(stderr, "\n[fcam_rb_lib] Timeout on 0x230! seg=%u chunk=%u\n", seg, chunk);
                    fcam_rb_dump_status(bar1);
                    wr(bar1, 0x250, 0);
                    wr(bar1, 0x210, 0);
                    fcam->timeout_count++;
                    return -4;
                }
            }
        }
        seg += slen;
    }

    wr(bar1, 0x250, 0);
    wr(bar1, 0x210, 0);

    /* Start CPU cache sync */
    dmabuf_sync(fcam->dma_fd, 1);

    uint64_t dur_us = now_us() - t0_start;
    fcam->last_fid = cur_fid;
    fcam->timeout_count = 0;

    if (out_buf_idx) *out_buf_idx = buf_idx;
    if (out_fid) *out_fid = cur_fid;
    if (out_dur_us) *out_dur_us = dur_us;
    return 1;
}

void fcam_rb_close(FcamRb *fcam)
{
    if (!fcam) return;
    if (fcam->rga_handle > 0) {
        releasebuffer_handle((rga_buffer_handle_t)fcam->rga_handle);
        fcam->rga_handle = 0;
    }
    if (fcam->dma_va && fcam->dma_va != MAP_FAILED) {
        munmap(fcam->dma_va, fcam->dma_len);
        fcam->dma_va = NULL;
    }
    if (fcam->dma_fd >= 0) {
        close(fcam->dma_fd);
        fcam->dma_fd = -1;
    }
}

