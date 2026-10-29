/*
 * test_feeder.c - RK3568: MPP HW HEVC/H.264 decode -> external CMA buffers (dma-heap)
 *   -> FPGA PCIe doorbell DMA into DDR3 frame slots -> display.  CPU never touches pixels.
 * Usage: test_feeder <bar1_hex> <input|-> [options]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "rk_mpi.h"
#include "rk_mpi_cmd.h"
#include "mpp_buffer.h"
#include "mpp_frame.h"
#include "mpp_packet.h"

#if defined(__has_include) && __has_include(<linux/dma-heap.h>)
#include <linux/dma-heap.h>
#else
struct dma_heap_allocation_data { uint64_t len; uint32_t fd; uint32_t fd_flags; uint64_t heap_flags; };
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)
#endif

/* FPGA BAR1 register offsets (bytes) */
#define R_MAGIC0 0x188
#define R_DRD_MAGIC 0x1E8
#define R_DISP_MAGIC 0x83C
#define R_HOST_LO 0x190
#define R_LEN 0x194
#define R_DST 0x198
#define R_SEQ 0x19C
#define R_DDR_EN 0x1A0
#define R_DONE 0x1C8
#define R_DISP_CTRL 0x800
#define R_FB_BASE 0x804
#define R_FB_SLOT 0x808
#define R_FB_STRIDE 0x80C
#define R_FB_UVOFF 0x810
#define R_FB_COMMIT 0x814
#define R_FB_STAT 0x820
#define R_DISP_NEWFR 0x828
#define R_DISP_UF 0x82C
#define MAGIC0_VAL 0x4D524432u
#define DRD_MAGIC_VAL 0x44445231u
#define DISP1_VAL 0x44535031u
#define DISP_OSD_VAL 0x4F534431u

#define PKT_SIZE (64u * 1024u)
#define MAX_OUTSTAND 16u
#define DMA_TIMEOUT_NS 2000000000ULL
#define FOUR_G 0x100000000ULL

enum { EXT_DMA = 0, EXT_DRM, EXT_DMAHEAP };

typedef struct {
    const char *codec; int ctx_codec; int fps; int bufs; size_t chunk;
    long long frames; int loop; const char *heap; int ext_type;
    MppBufferType ext_mpp; int have_ctrl; uint32_t ctrl;
} Options;

typedef struct { uint32_t w, h, hs, vs; size_t buf_size; } Info;

/* device access */
static volatile uint32_t *g_reg;
static int g_memfd = -1;
static void *g_reg_map = MAP_FAILED;
static inline void wr(uint32_t off, uint32_t v) { g_reg[off >> 2] = v; }
static inline uint32_t rd(uint32_t off) { return g_reg[off >> 2]; }

/* options / state */
static Options g_opt;
static Info g_info;
static int g_have_info;
static int g_in_fd = -1, g_in_regular, g_nbuf;
static MppCtx g_ctx;
static MppApi *g_mpi;
static MppPacket g_packet;
static char *g_pkt_buf;
static MppBufferGroup g_grp;
static int g_fd[64];
static uint64_t g_phys[64];
static size_t g_buf_len, g_frame_bytes;
static uint32_t g_fb_base, g_fb_slot, g_done_base, g_seq, g_newfr0, g_uf0;
static int g_last_slot = -1;
static volatile sig_atomic_t g_stop;

/* statistics */
static uint64_t g_frames, g_late, g_err, g_dma_sum_ns, g_dma_max_ns, g_wait_ns;
static uint64_t g_last_print_ns, g_last_frames, g_t_first;   /* review: g_t_first for summary fps */
static int g_exit_code;

static void on_signal(int sig) { (void)sig; g_stop = 1; }

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void dump_regs(void)
{
    uint32_t o;
    printf("!! doorbell timeout\n");
    for (o = 0x1C0; o <= 0x1EC; o += 4) printf("  0x%03X=0x%08X\n", o, rd(o));
    for (o = 0x800; o <= 0x830; o += 4) printf("  0x%03X=0x%08X\n", o, rd(o));
}

static uint32_t done_rel(void) { return rd(R_DONE) - g_done_base; }

/* wait until outstanding doorbells < n (n=0 => wait for all this process queued) */
static int wait_pending(uint32_t n)
{
    uint64_t t0 = now_ns();
    while ((uint32_t)(g_seq - done_rel()) > n) {
        if (now_ns() - t0 >= DMA_TIMEOUT_NS) return -1;
    }
    return 0;
}

/* DMA-heap external buffer allocation */
static int check_phys(int idx, void *va, long ps)
{
    int pfd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    size_t npages = (g_buf_len + (size_t)ps - 1) / (size_t)ps, k;
    uint64_t first = 0;
    if (pfd < 0) { perror("/proc/self/pagemap"); return -1; }
    for (k = 0; k < npages; k++) {
        uint64_t e = 0, pfn, pa;
        off_t off = (off_t)(((uintptr_t)va + k * (uint64_t)ps) / (uint64_t)ps) * 8;
        if (pread(pfd, &e, 8, off) != 8) {
            fprintf(stderr, "buf %d page %zu: pagemap read failed\n", idx, k); close(pfd); return -1;
        }
        pfn = e & ((1ULL << 55) - 1);
        if (!(e & (1ULL << 63)) || pfn == 0) {
            fprintf(stderr, "buf %d page %zu: not present\n", idx, k); close(pfd); return -1;
        }
        pa = pfn * (uint64_t)ps;
        if (k == 0) first = pa;
        else if (pa != first + k * (uint64_t)ps) {
            fprintf(stderr, "buf %d page %zu: PFN not contiguous\n", idx, k); close(pfd); return -1;
        }
    }
    close(pfd);
    if (first + g_buf_len > FOUR_G) {
        fprintf(stderr, "buf %d: above 4GB 0x%llx\n", idx,
                (unsigned long long)(first + g_buf_len));
        return -1;
    }
    g_phys[idx] = first;
    return 0;
}

static int alloc_ext_buffers(void)
{
    char path[128];
    int hfd, i;
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) { perror("sysconf(_SC_PAGESIZE)"); return -1; }
    snprintf(path, sizeof(path), "/dev/dma_heap/%s", g_opt.heap);
    hfd = open(path, O_RDWR | O_CLOEXEC);
    if (hfd < 0) { perror(path); return -1; }
    g_buf_len = (g_info.buf_size + 4095u) & ~(size_t)4095u;
    for (i = 0; i < g_opt.bufs; i++) {
        struct dma_heap_allocation_data data;
        MppBufferInfo info;
        void *va;
        memset(&data, 0, sizeof(data));
        data.len = g_buf_len;
        data.fd_flags = O_RDWR | O_CLOEXEC;
        if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) {
            perror("DMA_HEAP_IOCTL_ALLOC"); close(hfd); return -1;
        }
        g_fd[i] = data.fd;
        va = mmap(NULL, g_buf_len, PROT_READ, MAP_SHARED | MAP_POPULATE, g_fd[i], 0);
        if (va == MAP_FAILED) { perror("mmap"); close(hfd); return -1; }
        if (check_phys(i, va, ps) < 0) { munmap(va, g_buf_len); close(hfd); return -1; }
        if (munmap(va, g_buf_len) < 0) { perror("munmap"); close(hfd); return -1; }
        memset(&info, 0, sizeof(info));
        info.type = g_opt.ext_mpp;
        info.size = g_buf_len;
        info.fd = g_fd[i];
        info.index = i;
        if (mpp_buffer_commit(g_grp, &info) != MPP_OK) {
            fprintf(stderr, "mpp_buffer_commit failed at %d\n", i); close(hfd); return -1;
        }
    }
    g_nbuf = g_opt.bufs;
    close(hfd);
    printf("allocated %d external buffers, %zu bytes each, heap=%s\n",
           g_nbuf, g_buf_len, g_opt.heap);
    return 0;
}

/* info change */
static int handle_info_change(MppFrame frame)
{
    uint32_t w = mpp_frame_get_width(frame), h = mpp_frame_get_height(frame);
    uint32_t hs = mpp_frame_get_hor_stride(frame), vs = mpp_frame_get_ver_stride(frame);
    size_t bs = mpp_frame_get_buf_size(frame);
    int fmt = mpp_frame_get_fmt(frame);
    size_t fb;

    if ((uint32_t)(fmt & MPP_FRAME_FMT_MASK) != (uint32_t)MPP_FMT_YUV420SP) {
        fprintf(stderr, "unsupported frame fmt 0x%x (want NV12)\n", fmt);
        return 9;
    }
    if (!g_have_info) {
        printf("info change #1: %ux%u hor_stride=%u ver_stride=%u buf_size=%zu fmt=0x%x\n",
               w, h, hs, vs, bs, fmt);
        g_info.w = w; g_info.h = h; g_info.hs = hs; g_info.vs = vs; g_info.buf_size = bs;
        if (mpp_buffer_group_get_external(&g_grp, g_opt.ext_mpp) != MPP_OK) {
            fprintf(stderr, "mpp_buffer_group_get_external failed\n"); return 9;
        }
        if (alloc_ext_buffers() < 0) return 8;
        if (g_mpi->control(g_ctx, MPP_DEC_SET_EXT_BUF_GROUP, g_grp) != MPP_OK) {
            fprintf(stderr, "MPP_DEC_SET_EXT_BUF_GROUP failed\n"); return 9;
        }
        g_have_info = 1;
    } else if (w != g_info.w || h != g_info.h || hs != g_info.hs ||
               vs != g_info.vs || bs != g_info.buf_size) {
        fprintf(stderr, "re-init %ux%u hs=%u vs=%u buf=%zu != %ux%u hs=%u vs=%u buf=%zu\n",
                w, h, hs, vs, bs, g_info.w, g_info.h, g_info.hs, g_info.vs, g_info.buf_size);
        return 9;
    }
    fb = ((size_t)hs * vs * 3u / 2u + 255u) & ~(size_t)255u;
    if (fb > g_fb_slot || fb > g_buf_len) {
        fprintf(stderr, "frame_bytes %zu > slot %u / buf %zu\n", fb, g_fb_slot, g_buf_len);
        return 9;
    }
    g_frame_bytes = fb;
    printf("frame_bytes=%zu slot=%u base=0x%08X\n", g_frame_bytes, g_fb_slot, g_fb_base);
    wr(R_FB_STRIDE, hs);
    wr(R_FB_UVOFF, hs * vs);
    if (g_mpi->control(g_ctx, MPP_DEC_SET_INFO_CHANGE_READY, NULL) != MPP_OK) {
        fprintf(stderr, "MPP_DEC_SET_INFO_CHANGE_READY failed\n"); return 9;
    }
    mpp_frame_deinit(&frame);
    return 0;
}

/* display / DMA one frame */
static int dma_frame(uint64_t phys, uint32_t slot)
{
    uint32_t dst = g_fb_base + slot * g_fb_slot;
    size_t off;
    uint64_t t0 = 0, t1, d;

    for (off = 0; off < g_frame_bytes; off += g_opt.chunk) {
        uint32_t len = (uint32_t)(g_frame_bytes - off);
        if (len > g_opt.chunk) len = (uint32_t)g_opt.chunk;
        if (wait_pending(MAX_OUTSTAND - 1) < 0) { dump_regs(); return -1; }
        if (off == 0) t0 = now_ns();
        wr(R_HOST_LO, (uint32_t)(phys + off));
        wr(R_LEN, len);
        wr(R_DST, dst + (uint32_t)off);
        g_seq++;
        wr(R_SEQ, g_seq);
    }
    if (wait_pending(0) < 0) { dump_regs(); return -1; }
    t1 = now_ns();
    d = t1 - t0;
    g_dma_sum_ns += d;
    if (d > g_dma_max_ns) g_dma_max_ns = d;
    return 0;
}

/* returns 0 continue, 1 finish, 9 error */
static int handle_frame(MppFrame frame)
{
    MppBuffer buf = mpp_frame_get_buffer(frame);
    int idx, cand, k;
    int eos = mpp_frame_get_eos(frame) ? 1 : 0;   /* review: EOS may ride on the last real/err frame */
    uint32_t disp;
    uint64_t phys;

    if (eos && !buf) {
        printf("decoder EOS\n"); mpp_frame_deinit(&frame); return 1;
    }
    if (mpp_frame_get_errinfo(frame) || mpp_frame_get_discard(frame) || !buf) {
        g_err++; mpp_frame_deinit(&frame); return eos;
    }
    idx = mpp_buffer_get_index(buf);
    if (idx < 0 || idx >= g_nbuf) {
        int fd = mpp_buffer_get_fd(buf);
        idx = -1;
        for (k = 0; k < g_nbuf; k++) if (g_fd[k] == fd) { idx = k; break; }
        if (idx < 0) { g_err++; mpp_frame_deinit(&frame); return 0; }
    }
    phys = g_phys[idx];

    cand = (g_last_slot + 1) & 3;
    disp = rd(R_FB_STAT) & 3u;
    if (cand == (int)disp || cand == g_last_slot) {
        cand = (cand + 1) & 3;
        if (cand == (int)disp || cand == g_last_slot) cand = (cand + 1) & 3;
    }
    if (dma_frame(phys, (uint32_t)cand) < 0) { mpp_frame_deinit(&frame); return 9; }
    if (g_frames == 0) g_t_first = now_ns();

    if (g_opt.fps > 0) {
        static uint64_t t0;
        int64_t period = 1000000000LL / g_opt.fps, deadline;
        uint64_t now;
        if (g_frames == 0) t0 = now_ns();
        deadline = (int64_t)t0 + (int64_t)g_frames * period;
        now = now_ns();
        if ((int64_t)now > deadline + period) g_late++;   /* review: count before re-anchoring */
        if ((int64_t)now > deadline + 3 * period) {
            t0 = now - (uint64_t)((int64_t)g_frames * period);
            deadline = (int64_t)t0 + (int64_t)g_frames * period;
        }
        if ((int64_t)now < deadline) {
            struct timespec dl;
            dl.tv_sec = (time_t)(deadline / 1000000000LL);
            dl.tv_nsec = (long)(deadline % 1000000000LL);
            clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &dl, NULL);
        }
    }
    wr(R_FB_COMMIT, (((g_frames + 1) & 0xFFFFULL) << 16) | (uint64_t)cand);
    g_last_slot = cand;
    mpp_frame_deinit(&frame);
    g_frames++;
    if (eos) { printf("decoder EOS (with last frame)\n"); return 1; }
    return (g_opt.frames > 0 && (long long)g_frames >= g_opt.frames) ? 1 : 0;
}

static void print_stat(void)
{
    uint64_t now = now_ns(), dt = now - g_last_print_ns, df = g_frames - g_last_frames;
    double fps = dt ? (double)df * 1e9 / (double)dt : 0.0;
    double avg = g_frames ? (double)g_dma_sum_ns / (double)g_frames / 1e6 : 0.0;
    printf("[%6llus] frames=%llu fps=%.1f dma_avg=%.2fms dma_max=%.2fms late=%llu err=%llu "
           "newfr=%u uf=%u wait=%.0fms\n",
           (unsigned long long)(now / 1000000000ULL), (unsigned long long)g_frames, fps, avg,
           (double)g_dma_max_ns / 1e6, (unsigned long long)g_late, (unsigned long long)g_err,
           rd(R_DISP_NEWFR) - g_newfr0, rd(R_DISP_UF) - g_uf0, (double)g_wait_ns / 1e6);
    g_last_print_ns = now;
    g_last_frames = g_frames;
}

static void print_summary(void)
{
    double avg = g_frames ? (double)g_dma_sum_ns / (double)g_frames / 1e6 : 0.0;
    printf("---- summary ----\n");
    if (g_have_info)
        printf("info: %ux%u hor_stride=%u ver_stride=%u buf_size=%zu\n",
               g_info.w, g_info.h, g_info.hs, g_info.vs, g_info.buf_size);
    printf("frames=%llu avg_fps=%.1f avg_dma=%.2fms max_dma=%.2fms late=%llu err=%llu newfr=%u uf=%u wait=%.0fms\n",
           (unsigned long long)g_frames,
           (g_frames > 1) ? (double)(g_frames - 1) * 1e9 / (double)(now_ns() - g_t_first) : 0.0,
           avg, (double)g_dma_max_ns / 1e6,
           (unsigned long long)g_late, (unsigned long long)g_err,
           rd(R_DISP_NEWFR) - g_newfr0, rd(R_DISP_UF) - g_uf0, (double)g_wait_ns / 1e6);
}

static void cleanup(void)
{
    int i;
    if (g_mpi && g_ctx) g_mpi->reset(g_ctx);
    if (g_packet) mpp_packet_deinit(&g_packet);
    if (g_ctx) mpp_destroy(g_ctx);
    g_ctx = NULL;
    if (g_grp) mpp_buffer_group_put(g_grp);
    g_grp = NULL;
    for (i = 0; i < 64; i++) if (g_fd[i] > 0) { close(g_fd[i]); g_fd[i] = -1; }
    if (g_in_fd > 0) close(g_in_fd);
    if (g_pkt_buf) free(g_pkt_buf);
    if (g_reg_map != MAP_FAILED) munmap((void *)g_reg_map, 4096);
    if (g_memfd >= 0) close(g_memfd);
}

static int parse_ext_type(const char *s)
{
    if (!strcmp(s, "ext_dma")) return EXT_DMA;
    if (!strcmp(s, "drm")) return EXT_DRM;
    if (!strcmp(s, "dma_heap")) return EXT_DMAHEAP;
    fprintf(stderr, "bad --ext-type %s\n", s);
    return -1;
}

/* decode/feed loop; returns exit code */
static int run_loop(void)
{
    int pkt_pending = 0, eos_sent = 0, pkt_eos = 0;
    size_t pkt_len = 0;
    uint64_t t_quiet = 0;   /* 20261018: last EOS-sent / frame time; MPP may never emit an EOS frame (e.g. empty input) */

    while (!g_stop) {
        if (!eos_sent) {
            if (!pkt_pending) {
                ssize_t n;
                do { n = read(g_in_fd, g_pkt_buf, PKT_SIZE); } while (n < 0 && errno == EINTR);
                if (n > 0) { pkt_len = (size_t)n; pkt_eos = 0; pkt_pending = 1; }
                else if (n == 0) {
                    if (g_opt.loop && g_in_regular) { lseek(g_in_fd, 0, SEEK_SET); continue; }
                    pkt_len = 0; pkt_eos = 1; pkt_pending = 1;
                } else { fprintf(stderr, "read: %s\n", strerror(errno)); return 1; }
            }
            if (pkt_pending) {
                mpp_packet_set_pos(g_packet, g_pkt_buf);
                mpp_packet_set_length(g_packet, pkt_len);
                if (pkt_eos) mpp_packet_set_eos(g_packet);
                else mpp_packet_clr_eos(g_packet);
                if (g_mpi->decode_put_packet(g_ctx, g_packet) == MPP_OK) {
                    pkt_pending = 0;
                    if (pkt_eos) { eos_sent = 1; t_quiet = now_ns(); }
                }
            }
        }
        {
            MppFrame frame = NULL;
            uint64_t t0 = now_ns();
            MPP_RET gr = g_mpi->decode_get_frame(g_ctx, &frame);
            if (gr == MPP_OK && frame) {
                t_quiet = now_ns();
                if (mpp_frame_get_info_change(frame)) {
                    int hrc = handle_info_change(frame);
                    if (hrc) return hrc;
                } else {
                    int frc = handle_frame(frame);
                    if (frc == 1) break;
                    if (frc == 9) return 9;
                }
            } else {
                g_wait_ns += now_ns() - t0;
            }
        }
        if (eos_sent && now_ns() - t_quiet >= 2000000000ULL) {
            fprintf(stderr, "no decoder EOS 2 s after input EOF (%llu frames)\n", (unsigned long long)g_frames);
            if (g_frames == 0) return 3;   /* empty or undecodable input */
            break;
        }
        if (now_ns() - g_last_print_ns >= 1000000000ULL) print_stat();
    }
    return 0;
}

static void usage(const char *p)
{
    fprintf(stderr,
        "usage: %s <bar1_hex> <input|-> [options]\n"
        "  --codec hevc|h264     --fps N(0=unlimited)  --bufs N\n"
        "  --chunk BYTES(256-mult <=4MB)  --frames N(0=all)  --loop\n"
        "  --heap NAME  --ext-type ext_dma|drm|dma_heap  --ctrl HEX\n", p);
}

int main(int argc, char **argv)
{
    uint32_t bar1;
    int i, rc;
    struct sigaction sa;
    struct stat st;

    memset(&g_opt, 0, sizeof(g_opt));
    for (i = 0; i < 64; i++) g_fd[i] = -1;
    g_opt.codec = "hevc"; g_opt.fps = 30; g_opt.bufs = 24;
    g_opt.chunk = 262144; g_opt.frames = 0; g_opt.heap = "cma";
    g_opt.ext_type = EXT_DMA; g_opt.ext_mpp = MPP_BUFFER_TYPE_EXT_DMA;

    if (argc < 3) { usage(argv[0]); return 2; }
    for (i = 3; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--codec") && i + 1 < argc) g_opt.codec = argv[++i];
        else if (!strcmp(a, "--fps") && i + 1 < argc) g_opt.fps = (int)strtoll(argv[++i], NULL, 0);
        else if (!strcmp(a, "--bufs") && i + 1 < argc) g_opt.bufs = (int)strtoll(argv[++i], NULL, 0);
        else if (!strcmp(a, "--chunk") && i + 1 < argc) g_opt.chunk = (size_t)strtoll(argv[++i], NULL, 0);
        else if (!strcmp(a, "--frames") && i + 1 < argc) g_opt.frames = strtoll(argv[++i], NULL, 0);
        else if (!strcmp(a, "--loop")) g_opt.loop = 1;
        else if (!strcmp(a, "--heap") && i + 1 < argc) g_opt.heap = argv[++i];
        else if (!strcmp(a, "--ext-type") && i + 1 < argc) {
            int t = parse_ext_type(argv[++i]);
            if (t < 0) return 2;
            g_opt.ext_type = t;
        }
        else if (!strcmp(a, "--ctrl") && i + 1 < argc) {
            g_opt.ctrl = (uint32_t)strtoul(argv[++i], NULL, 0); g_opt.have_ctrl = 1;
        }
        else { fprintf(stderr, "unknown option: %s\n", a); usage(argv[0]); return 2; }
    }

    if (!strcmp(g_opt.codec, "hevc")) g_opt.ctx_codec = MPP_VIDEO_CodingHEVC;
    else if (!strcmp(g_opt.codec, "h264")) g_opt.ctx_codec = MPP_VIDEO_CodingAVC;
    else { fprintf(stderr, "bad --codec %s\n", g_opt.codec); return 2; }
    if (g_opt.ext_type == EXT_DRM) g_opt.ext_mpp = MPP_BUFFER_TYPE_DRM;
    else if (g_opt.ext_type == EXT_DMAHEAP) g_opt.ext_mpp = MPP_BUFFER_TYPE_DMA_HEAP;
    if (g_opt.bufs < 1 || g_opt.bufs > 64) { fprintf(stderr, "--bufs must be 1..64\n"); return 2; }
    if (g_opt.chunk == 0 || (g_opt.chunk & 255u) != 0 || g_opt.chunk > (4u << 20)) {
        fprintf(stderr, "--chunk must be a 256-multiple <= 4MB\n"); return 2;
    }
    if (g_opt.fps < 0) { fprintf(stderr, "--fps must be >= 0\n"); return 2; }

    /* map BAR1 registers */
    bar1 = (uint32_t)strtoul(argv[1], NULL, 16);
    g_memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_memfd < 0) { perror("/dev/mem"); return 1; }
    g_reg_map = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, g_memfd, bar1);
    if (g_reg_map == MAP_FAILED) { perror("mmap /dev/mem"); return 1; }
    g_reg = (volatile uint32_t *)g_reg_map;

    {
        uint32_t a = rd(R_MAGIC0), b = rd(R_DRD_MAGIC), c = rd(R_DISP_MAGIC);
        if (a != MAGIC0_VAL || b != DRD_MAGIC_VAL || (c != DISP1_VAL && c != DISP_OSD_VAL)) {
            fprintf(stderr, "magic mismatch: 0x188=0x%08X 0x1E8=0x%08X 0x83C=0x%08X\n", a, b, c);
            return 7;
        }
    }

    if (argv[2][0] == '-' && argv[2][1] == '\0') g_in_fd = 0;
    else { g_in_fd = open(argv[2], O_RDONLY); if (g_in_fd < 0) { perror(argv[2]); return 1; } }
    if (fstat(g_in_fd, &st) == 0 && S_ISREG(st.st_mode)) g_in_regular = 1;

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    wr(R_DDR_EN, 1);
    if (g_opt.have_ctrl) wr(R_DISP_CTRL, g_opt.ctrl);
    else wr(R_DISP_CTRL, rd(R_DISP_CTRL) | 1u);
    g_fb_base = rd(R_FB_BASE);
    g_fb_slot = rd(R_FB_SLOT);
    g_newfr0 = rd(R_DISP_NEWFR);
    g_uf0 = rd(R_DISP_UF);
    {
        uint32_t v = rd(R_DONE), w;
        for (i = 0; i < 200; i++) {
            struct timespec ts = { 0, 5000000 };
            nanosleep(&ts, NULL);
            w = rd(R_DONE);
            if (w == v) break;
            v = w;
        }
        g_done_base = v;
    }
    printf("bar1=0x%08X fb_base=0x%08X fb_slot=0x%08X\n", bar1, g_fb_base, g_fb_slot);

    rc = mpp_create(&g_ctx, &g_mpi);
    if (rc != MPP_OK) { fprintf(stderr, "mpp_create=%d\n", rc); g_exit_code = 1; goto out; }
    { RK_U32 split = 1; g_mpi->control(g_ctx, MPP_DEC_SET_PARSER_SPLIT_MODE, &split); }
    rc = mpp_init(g_ctx, MPP_CTX_DEC, (MppCodingType)g_opt.ctx_codec);
    if (rc != MPP_OK) { fprintf(stderr, "mpp_init=%d\n", rc); g_exit_code = 1; goto out; }
    { RK_S64 timeout = 5; g_mpi->control(g_ctx, MPP_SET_OUTPUT_TIMEOUT, &timeout); }

    g_pkt_buf = malloc(PKT_SIZE);
    if (!g_pkt_buf) { fprintf(stderr, "malloc packet buf\n"); g_exit_code = 1; goto out; }
    if (mpp_packet_init(&g_packet, g_pkt_buf, PKT_SIZE) != MPP_OK) {
        fprintf(stderr, "mpp_packet_init failed\n"); g_exit_code = 1; goto out;
    }

    g_last_print_ns = now_ns();
    g_exit_code = run_loop();
    print_summary();

out:
    cleanup();
    return g_exit_code;
}
