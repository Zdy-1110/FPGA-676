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
#include <getopt.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>

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

#define FRAME_W             960u
#define FRAME_H             540u
#define BYTES_PER_PX        2u
#define FRAME_BYTES         (FRAME_W * FRAME_H * BYTES_PER_PX) /* 1,036,800 B */

#define DDR_RB_MAX_SEG      32768u      /* FPGA DDR readback single transfer limit (<=32KB, 512B aligned) */
#define DDR_RAM_WORD_OFF    2048u       /* 128-bit word offset in FPGA DMA RAM (32KB offset) */
#define MWR_CHUNK_MAX       8192u       /* MWr chunk size (DW-aligned, smooth PCIe TLP transmission) */

#define DEFAULT_BAR1_ADDR   0xf0204000ULL
#define POLL_TIMEOUT_US     50000ULL    /* 50 ms timeout for hardware pollings */
#define FRAME_WAIT_TIMEOUT_US 100000ULL /* 100 ms timeout for new camera frame commit */

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

static void dump_hub_status(volatile uint32_t *bar1)
{
    fprintf(stderr, "\n[fcam_rb] Hub Status Registers (0x1C0 - 0x1EC):\n");
    for (uint32_t off = 0x1C0; off <= 0x1EC; off += 4) {
        fprintf(stderr, "  BAR1[0x%03X] = 0x%08X\n", off, rd(bar1, off));
    }
    fprintf(stderr, "[fcam_rb] Camera / Display Diagnostics:\n");
    fprintf(stderr, "  BAR1[0x800 DISP_CTRL] = 0x%08X\n", rd(bar1, 0x800));
    fprintf(stderr, "  BAR1[0x804 FB_BASE]   = 0x%08X\n", rd(bar1, 0x804));
    fprintf(stderr, "  BAR1[0x820 FB_STAT]   = 0x%08X (fid=%u, slot=%u)\n",
            rd(bar1, 0x820), (rd(bar1, 0x820) >> 16) & 0xFFFFu, rd(bar1, 0x820) & 0x3u);
    fprintf(stderr, "  BAR1[0x8A0 CAM_STAT0] = 0x%08X\n", rd(bar1, 0x8A0));
    fprintf(stderr, "  BAR1[0x8A4 CAM_STAT1] = 0x%08X\n", rd(bar1, 0x8A4));
    fprintf(stderr, "  BAR1[0x8A8 CAM_URG]   = 0x%08X\n\n", rd(bar1, 0x8A8));
}

static int check_phys_range(void *va, size_t len, long ps, uint64_t *out_pa)
{
    int pfd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    if (pfd < 0) {
        perror("[fcam_rb] open /proc/self/pagemap");
        return -1;
    }
    size_t npages = (len + (size_t)ps - 1) / (size_t)ps;
    uint64_t first = 0;

    for (size_t k = 0; k < npages; k++) {
        uint64_t e = 0;
        off_t off = (off_t)(((uintptr_t)va + k * (uint64_t)ps) / (uint64_t)ps) * 8;
        if (pread(pfd, &e, 8, off) != 8) {
            fprintf(stderr, "[fcam_rb] pagemap read failed on page %zu\n", k);
            close(pfd);
            return -1;
        }
        uint64_t pfn = e & ((1ULL << 55) - 1);
        if (!(e & (1ULL << 63)) || pfn == 0) {
            fprintf(stderr, "[fcam_rb] page %zu not present in RAM\n", k);
            close(pfd);
            return -1;
        }
        uint64_t pa = pfn * (uint64_t)ps;
        if (k == 0) {
            first = pa;
        } else if (pa != first + k * (uint64_t)ps) {
            fprintf(stderr, "[fcam_rb] CMA memory not physically contiguous at page %zu\n", k);
            close(pfd);
            return -1;
        }
    }
    close(pfd);

    if (first + len > 0x100000000ULL) {
        fprintf(stderr, "[fcam_rb] Physical address 0x%llx is above 4GB limit\n",
                (unsigned long long)(first + len));
        return -1;
    }
    if (out_pa) *out_pa = first;
    return 0;
}

static int alloc_cma_buf(size_t len, int *out_fd, void **out_va, uint64_t *out_pa)
{
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) ps = 4096;

    int hfd = open("/dev/dma_heap/cma", O_RDWR | O_CLOEXEC);
    if (hfd < 0) {
        perror("[fcam_rb] open /dev/dma_heap/cma");
        return -1;
    }

    struct dma_heap_allocation_data data;
    memset(&data, 0, sizeof(data));
    data.len = (len + 4095u) & ~(uint64_t)4095u;
    data.fd_flags = O_RDWR | O_CLOEXEC;

    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) {
        perror("[fcam_rb] ioctl DMA_HEAP_IOCTL_ALLOC");
        close(hfd);
        return -1;
    }
    close(hfd);

    void *va = mmap(NULL, (size_t)data.len, PROT_READ | PROT_WRITE,
                    MAP_SHARED | MAP_POPULATE, (int)data.fd, 0);
    if (va == MAP_FAILED) {
        perror("[fcam_rb] mmap dma-heap");
        close((int)data.fd);
        return -1;
    }

    if (check_phys_range(va, (size_t)data.len, ps, out_pa) < 0) {
        munmap(va, (size_t)data.len);
        close((int)data.fd);
        return -1;
    }

    *out_fd = (int)data.fd;
    *out_va = va;
    return 0;
}

static inline void dmabuf_sync(int fd, int start)
{
    if (fd < 0) return;
    struct dma_buf_sync sync;
    memset(&sync, 0, sizeof(sync));
    sync.flags = DMA_BUF_SYNC_READ | (start ? DMA_BUF_SYNC_START : DMA_BUF_SYNC_END);
    if (ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync) < 0) {
        perror("[fcam_rb] DMA_BUF_IOCTL_SYNC failed");
    }
}

/*
 * ddr_to_host_frame():
 *   Read one full 960x540 RGB565 frame (1,036,800 B) from DDR physical address `ddr_addr`
 *   to host CMA buffer `dst_phys`.
 *   Segmented into <=32KB slices (512B aligned), each transferred via:
 *     1. DDR -> FPGA RAM (offset 2048 words = 32KB)
 *     2. FPGA RAM -> Host CMA (MWr in 8KB chunks)
 */
static int ddr_to_host_frame(volatile uint32_t *bar1, uint32_t ddr_addr, uint64_t dst_phys)
{
    uint32_t seg = 0;
    while (seg < FRAME_BYTES) {
        uint32_t slen = FRAME_BYTES - seg;
        if (slen > DDR_RB_MAX_SEG) slen = DDR_RB_MAX_SEG;

        /* Step 1: Trigger DDR -> FPGA RAM readback */
        wr(bar1, 0x1A8, ddr_addr + seg);
        wr(bar1, 0x1AC, slen);
        wr(bar1, 0x1B0, DDR_RAM_WORD_OFF);

        uint32_t old_done = rd(bar1, 0x1DC);
        wr(bar1, 0x1B4, 1);

        uint64_t t0 = now_us();
        while (rd(bar1, 0x1DC) == old_done) {
            if (now_us() - t0 >= POLL_TIMEOUT_US) {
                fprintf(stderr, "\n[fcam_rb] ERROR: Timeout waiting for 0x1DC (DDR->RAM done)! seg=%u slen=%u\n",
                        seg, slen);
                dump_hub_status(bar1);
                wr(bar1, 0x250, 0);
                wr(bar1, 0x210, 0);
                return -1;
            }
        }

        /* Step 2: Trigger FPGA RAM -> Host CMA MWr */
        for (uint32_t chunk = 0; chunk < slen; chunk += MWR_CHUNK_MAX) {
            uint32_t clen = slen - chunk;
            if (clen > MWR_CHUNK_MAX) clen = MWR_CHUNK_MAX;

            /* RAM word offset encoded in 16-bit words: (RAM_WORD_OFF + chunk/16) * 8 */
            wr(bar1, 0x210, (DDR_RAM_WORD_OFF + (chunk >> 4)) * 8u);
            wr(bar1, 0x200, (uint32_t)(dst_phys + seg + chunk));
            wr(bar1, 0x204, 0);
            wr(bar1, 0x220, 1023);              /* Traditional max */
            wr(bar1, 0x250, clen >> 2);         /* Extended MWr length in DW */
            wr(bar1, 0x240, 0);                 /* Trigger MWr transfer */

            t0 = now_us();
            for (;;) {
                uint32_t v = rd(bar1, 0x230);
                if (v == 0xFFFFFFFFu) {
                    fprintf(stderr, "\n[fcam_rb] ERROR: PCIe EP disconnected / link down (0x230 == 0xFFFFFFFF)!\n");
                    dump_hub_status(bar1);
                    return -2;
                }
                if (v != 0) {
                    /* 0x230 is clear-on-read; non-zero means transfer completed */
                    break;
                }
                if (now_us() - t0 >= POLL_TIMEOUT_US) {
                    fprintf(stderr, "\n[fcam_rb] ERROR: Timeout waiting for 0x230 (RAM->Host MWr done)! seg=%u chunk=%u clen=%u\n",
                            seg, chunk, clen);
                    dump_hub_status(bar1);
                    wr(bar1, 0x250, 0);
                    wr(bar1, 0x210, 0);
                    return -3;
                }
            }
        }
        seg += slen;
    }

    wr(bar1, 0x250, 0);
    wr(bar1, 0x210, 0);
    return 0;
}

static void print_usage(const char *prog)
{
    printf("Usage:\n");
    printf("  %s [options]\n\n", prog);
    printf("Options:\n");
    printf("  --bar1 ADDR        FPGA BAR1 physical address (default: 0x%08llx)\n", (unsigned long long)DEFAULT_BAR1_ADDR);
    printf("  --count N          Number of frames to read (default: 1)\n");
    printf("  --out PATTERN      Output file path pattern (e.g. /tmp/fcam_%%02d.rgb565)\n");
    printf("  --interval-ms M    Interval between frames in milliseconds (default: 0)\n");
    printf("  --nowait           Do not wait for frame commit boundary, read latest complete frame immediately\n");
    printf("  --force-buf 0|1    Force specific buffer (0=FB_BASE, 1=FB_BASE+0x100000)\n");
    printf("  -h, --help         Show this help message\n");
}

int main(int argc, char **argv)
{
    uint64_t bar1_phys = DEFAULT_BAR1_ADDR;
    uint32_t count = 1;
    char out_pattern[512] = "";
    uint32_t interval_ms = 0;
    bool nowait = false;
    int force_buf = -1;

    static struct option long_opts[] = {
        {"bar1",        required_argument, NULL, 'b'},
        {"count",       required_argument, NULL, 'c'},
        {"out",         required_argument, NULL, 'o'},
        {"interval-ms", required_argument, NULL, 'i'},
        {"nowait",      no_argument,       NULL, 'n'},
        {"force-buf",   required_argument, NULL, 'f'},
        {"help",        no_argument,       NULL, 'h'},
        {NULL, 0, NULL, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "b:c:o:i:nf:h", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'b':
                bar1_phys = strtoull(optarg, NULL, 0);
                break;
            case 'c':
                count = (uint32_t)strtoul(optarg, NULL, 0);
                if (count == 0) count = 1;
                break;
            case 'o':
                snprintf(out_pattern, sizeof(out_pattern), "%s", optarg);
                break;
            case 'i':
                interval_ms = (uint32_t)strtoul(optarg, NULL, 0);
                break;
            case 'n':
                nowait = true;
                break;
            case 'f':
                force_buf = atoi(optarg);
                if (force_buf != 0 && force_buf != 1) {
                    fprintf(stderr, "Error: --force-buf must be 0 or 1\n");
                    return 1;
                }
                break;
            case 'h':
            default:
                print_usage(argv[0]);
                return (opt == 'h') ? 0 : 1;
        }
    }

    printf("============================================================\n");
    printf(" FCAM Readback Tool (FPGA DDR -> Host CMA via PCIe DMA)\n");
    printf("   BAR1 Phys Addr : 0x%08llX\n", (unsigned long long)bar1_phys);
    printf("   Frame Size     : %ux%u RGB565 (%u bytes)\n", FRAME_W, FRAME_H, FRAME_BYTES);
    printf("   Frame Count    : %u\n", count);
    if (out_pattern[0])
        printf("   Output Pattern : %s\n", out_pattern);
    else
        printf("   Output Pattern : (none, benchmark only)\n");
    if (interval_ms > 0)
        printf("   Interval       : %u ms\n", interval_ms);
    printf("============================================================\n");

    /* Map BAR1 via /dev/mem */
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("[fcam_rb] open /dev/mem");
        return 1;
    }

    volatile uint32_t *bar1 = (volatile uint32_t *)mmap(
        NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, (off_t)bar1_phys);
    if (bar1 == MAP_FAILED) {
        perror("[fcam_rb] mmap BAR1");
        close(mem_fd);
        return 1;
    }

    /* Verify hardware magic signatures */
    uint32_t magic_ddr = rd(bar1, 0x1E8);
    uint32_t magic_osd = rd(bar1, 0x83C);
    printf("[fcam_rb] Checking FPGA hardware signature...\n");
    printf("  BAR1[0x1E8 DDR Magic] = 0x%08X (expected 0x44445231 'DDR1')\n", magic_ddr);
    printf("  BAR1[0x83C OSD Magic] = 0x%08X (expected 0x4F534431 'OSD1')\n", magic_osd);

    if (magic_ddr != 0x44445231u || magic_osd != 0x4F534431u) {
        fprintf(stderr, "[fcam_rb] WARNING: Hardware signature mismatch! Verify BAR1 physical address.\n");
    }

    uint32_t fb_base = rd(bar1, 0x804);
    if (fb_base == 0) {
        fb_base = 0x04000000u; /* Default slot0 base */
        printf("[fcam_rb] 0x804 FB_BASE is 0, using default 0x%08X\n", fb_base);
    } else {
        printf("[fcam_rb] FB_BASE (0x804) = 0x%08X\n", fb_base);
    }

    /* Allocate CMA buffer for receiving frame */
    int dma_fd = -1;
    void *dma_va = NULL;
    uint64_t dma_pa = 0;
    if (alloc_cma_buf(FRAME_BYTES, &dma_fd, &dma_va, &dma_pa) < 0) {
        fprintf(stderr, "[fcam_rb] Failed to allocate CMA buffer!\n");
        munmap((void *)bar1, 4096);
        close(mem_fd);
        return 1;
    }
    printf("[fcam_rb] Allocated CMA Buffer: VA=%p, PA=0x%llx, Len=%u\n",
           dma_va, (unsigned long long)dma_pa, FRAME_BYTES);

    uint64_t *frame_times_us = (uint64_t *)calloc(count, sizeof(uint64_t));
    if (!frame_times_us) {
        perror("calloc");
        return 1;
    }

    uint32_t last_fid = (rd(bar1, 0x820) >> 16) & 0xFFFFu;
    printf("[fcam_rb] Initial stat_frame_id = %u (slot=%u)\n", last_fid, rd(bar1, 0x820) & 3u);

    int rc = 0;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t cur_fid = last_fid;
        int buf_idx = 0;

        /* Wait for new camera frame commit if required */
        if (!nowait) {
            uint64_t t_wait_start = now_us();
            while (((rd(bar1, 0x820) >> 16) & 0xFFFFu) == last_fid) {
                if (now_us() - t_wait_start >= FRAME_WAIT_TIMEOUT_US) {
                    fprintf(stderr, "\n[fcam_rb] Frame %u: Timeout waiting for new camera frame commit (0x820 stat_frame_id unchanged from %u)!\n",
                            i, last_fid);
                    dump_hub_status(bar1);
                    rc = -10;
                    goto cleanup;
                }
                usleep(500); /* 0.5 ms sleep while polling */
            }
            cur_fid = (rd(bar1, 0x820) >> 16) & 0xFFFFu;
            last_fid = cur_fid;
        } else {
            cur_fid = (rd(bar1, 0x820) >> 16) & 0xFFFFu;
        }

        /* Determine completed buffer (Double buffer: odd frames in buf1, even in buf0) */
        if (force_buf >= 0) {
            buf_idx = force_buf;
        } else {
            buf_idx = (int)(cur_fid & 1u);
        }

        uint32_t ddr_addr = fb_base + (buf_idx ? 0x00100000u : 0u);

        uint64_t t_frame_start = now_us();

        /* Execute DDR -> RAM -> Host PCIe DMA */
        int err = ddr_to_host_frame(bar1, ddr_addr, dma_pa);
        if (err < 0) {
            fprintf(stderr, "[fcam_rb] Readback failed on frame %u (rc=%d)!\n", i, err);
            rc = err;
            goto cleanup;
        }

        /* CPU reads DMA buffer: synchronize cache */
        dmabuf_sync(dma_fd, 1);

        /* Write output file if requested */
        if (out_pattern[0]) {
            char filepath[1024];
            if (strstr(out_pattern, "%")) {
                snprintf(filepath, sizeof(filepath), out_pattern, i);
            } else {
                if (count == 1) {
                    snprintf(filepath, sizeof(filepath), "%s", out_pattern);
                } else {
                    snprintf(filepath, sizeof(filepath), "%s_%02u", out_pattern, i);
                }
            }

            FILE *fp = fopen(filepath, "wb");
            if (!fp) {
                fprintf(stderr, "[fcam_rb] Failed to open output file '%s': %s\n",
                        filepath, strerror(errno));
            } else {
                size_t written = fwrite(dma_va, 1, FRAME_BYTES, fp);
                fclose(fp);
                if (written != FRAME_BYTES) {
                    fprintf(stderr, "[fcam_rb] Partial write to '%s' (%zu / %u)\n",
                            filepath, written, FRAME_BYTES);
                }
            }
        }

        dmabuf_sync(dma_fd, 0);

        uint64_t t_frame_end = now_us();
        uint64_t dur_us = t_frame_end - t_frame_start;
        frame_times_us[i] = dur_us;

        printf("  [Frame %3u/%3u] FID=%5u Buf=%d DDR=0x%08X Time=%6llu us (%.2f ms)\n",
               i + 1, count, cur_fid, buf_idx, ddr_addr,
               (unsigned long long)dur_us, dur_us / 1000.0);

        if (interval_ms > 0 && i + 1 < count) {
            usleep(interval_ms * 1000);
        }
    }

    /* Calculate statistics */
    uint64_t sum_us = 0;
    uint64_t min_us = (uint64_t)-1;
    uint64_t max_us = 0;
    for (uint32_t i = 0; i < count; i++) {
        uint64_t t = frame_times_us[i];
        sum_us += t;
        if (t < min_us) min_us = t;
        if (t > max_us) max_us = t;
    }
    double avg_us = (double)sum_us / count;
    double fps = (avg_us > 0.0) ? (1000000.0 / avg_us) : 0.0;

    printf("============================================================\n");
    printf(" Readback Benchmark Summary (%u frames):\n", count);
    printf("   Min Read Time : %llu us (%.2f ms)\n", (unsigned long long)min_us, min_us / 1000.0);
    printf("   Max Read Time : %llu us (%.2f ms)\n", (unsigned long long)max_us, max_us / 1000.0);
    printf("   Avg Read Time : %.1f us (%.2f ms)\n", avg_us, avg_us / 1000.0);
    printf("   Estimated FPS : %.2f fps (DMA transfer limit)\n", fps);
    printf("============================================================\n");

cleanup:
    free(frame_times_us);
    if (dma_va && dma_va != MAP_FAILED) munmap(dma_va, (FRAME_BYTES + 4095u) & ~(size_t)4095u);
    if (dma_fd >= 0) close(dma_fd);
    if (bar1 && bar1 != MAP_FAILED) munmap((void *)bar1, 4096);
    if (mem_fd >= 0) close(mem_fd);

    return rc;
}
