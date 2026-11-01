/*
 * usb_feed.c - RK3568: up to 4 inputs (USB cameras or video files) -> one gst child per input
 *   camera: (v4l2src ! mppjpegdec ! video/x-raw,format=NV12 ! fdsink fd=1)
 *   file:   (filesrc ! qtdemux ! h264/h265parse ! mppvideodec ! videoconvert ! video/x-raw,format=NV12 ! fdsink fd=1)
 *   -> pipe read -> RGA scale/format conversion (NV12 or RGB565) in CMA buffer ->
 *   FPGA PCIe doorbell DMA into FB_BASE + slot*SLOT_SIZE -> 0x814 commit.
 *
 * One process, one thread per input: the doorbell registers (0x190/0x194/0x198/0x19C)
 * and the commit register (0x814) are a single global set, so every frame's
 * doorbell+commit sequence is serialised with one mutex.
 *
 * Usage: usb_feed [options]
 *   --cam <dev>:<slot>[:<fps>]   repeatable, up to 4; capture thread from camera
 *                                (e.g. --cam /dev/video17:1 --cam /dev/video19:2)
 *   --file <path>:<slot>[:<fps>] repeatable, up to 4; playback thread from video file
 *   --file-once                  play video files once and exit (default: loop)
 *   --slot0-rgb565               output RGB565 (stride 1920, 960x540) for slot 0
 *   --dump-slot0 N[:K]           dump N frames from slot0 (every K frames, default 30)
 *                                to /tmp/slot0_dump/f%04d.rgb565 (1036800 bytes,
 *                                960x540 RGB565 little-endian: low byte G[2:0]|B[4:0],
 *                                high byte R[4:0]|G[5:3]; uint16 [15:11] R, [10:5] G, [4:0] B)
 *   --dev <path>     single-camera mode capture node (default /dev/video17)
 *   --slot <0-3>     single-camera mode display slot (default 2)
 *   --bar1 <hex>     FPGA BAR1 physical address (default f0204000)
 *   --src WxH        capture size (default 1280x720)
 *   --dst WxH        display size (default 1920x1080, use 960x540 for 2x2)
 *   --fps N          target rate per camera, 0 = unlimited (default 30)
 *   --frames N       frames per camera, 0 = forever (default 0)
 *   --csv <path>     per-frame CSV; multi-camera writes <path>.<slot>.csv
 *   --gst-log <path> gst stderr log (default /tmp/usb_feed_gst.log);
 *                    multi-camera writes <path>.<slot>.log
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
#include <spawn.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "im2d.h"
#include "vdec_mpp.h"
#include "quad_npu.h"
#include "adas.h"

#if defined(__has_include) && __has_include(<linux/dma-heap.h>)
#include <linux/dma-heap.h>
#else
struct dma_heap_allocation_data { uint64_t len; uint32_t fd; uint32_t fd_flags; uint64_t heap_flags; };
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

extern char **environ;

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

#define DMA_CHUNK (256u * 1024u)
#define MAX_OUTSTAND 16u
#define DMA_TIMEOUT_NS 2000000000ULL
#define FOUR_G 0x100000000ULL
#define RGA_DST_BUFS 2
#define MAX_CAMS 4
#define DMA_WARN_STREAK 2
#define DMA_DEAD_STREAK 20

enum {
    CODEC_UNKNOWN = 0,
    CODEC_H264 = 1,
    CODEC_H265 = 2
};

typedef struct {
    const char *dev;
    const char *csv;
    const char *gst_log;
    uint32_t bar1;
    int slot;                 /* single-camera default slot */
    int src_w, src_h;
    int dst_w, dst_h;
    int fps;                  /* default per-camera fps */
    long long frames;
    int file_once;            /* 1 = exit when file finishes, 0 = loop */
    int slot0_rgb565;         /* 1 = slot0 outputs RGB565 (960x540, stride 1920) */
    int dec_bufs;             /* decoder external buffer count per video */
    const char *npu_model;    /* RKNN model path (NULL = disabled) */
    const char *adas_cfg;     /* ADAS config path (NULL = disabled) */
    const char *nav_path;     /* navigation route (.nav) path (NULL = disabled) */
    int npu_weights[4];       /* SWRR weights */
    float npu_conf;           /* confidence threshold */
    int npu_dump;             /* dump count */
    int dump_slot0_n;         /* dump slot0 frames count */
    int dump_slot0_k;         /* dump slot0 interval (default 30) */
} Options;

typedef struct {
    /* configuration */
    int index;
    int is_file;              /* 0 = cam (v4l2src), 1 = file (filesrc) */
    int is_video;             /* 1 = video (MPP direct decode to CMA) */
    int is_still;             /* 1 = still image (decode once, loop push) */
    char dev[512];            /* device path or video file path */
    int slot;
    int fps;                  /* effective per-channel rate */
    int frames;               /* 0 = forever */
    int codec;                /* CODEC_H264 or CODEC_H265 (for file) */
    int src_w, src_h;         /* input video dimensions */
    int src_pad_h;            /* padded source height (src_pad_h for file = (src_h + 15) & ~15; for cam = src_h) */
    int dst_w, dst_h;         /* output display dimensions */
    int dst_format;           /* RK_FORMAT_YCbCr_420_SP or RK_FORMAT_RGB_565 */
    size_t frame_bytes;       /* commit/dma transfer bytes */
    size_t dst_len;           /* dma buffer allocation bytes */
    char csv_path[512];
    char log_path[512];

    /* still image buffer */
    void *still_nv12;
    size_t still_bytes;
    int still_w, still_h;

    /* gst child + pipe */
    pid_t pid;
    int fd;
    uint64_t frames_loop_count; /* frames decoded in current loop cycle */

    /* MPP decoder and cached RGA handles for --video */
    VDec vdec;
    rga_buffer_handle_t vdec_src_handles[VDEC_MAX_BUFS];
    int vdec_src_fds[VDEC_MAX_BUFS];

    /* capture buffer (CMA, read from the pipe) + RGA source handle */
    int cap_fd;
    void *cap_va;
    size_t cap_len;
    size_t cap_bytes;
    rga_buffer_handle_t src_handle;

    /* RGA destination buffers (CMA, physical < 4GB) */
    int dst_fd[RGA_DST_BUFS];
    void *dst_va[RGA_DST_BUFS];
    uint64_t dst_phys[RGA_DST_BUFS];
    rga_buffer_handle_t dst_handle[RGA_DST_BUFS];
    int dst_idx;

    /* statistics (written by the owner thread, read by the printer) */
    uint64_t frames_done, last_frames, t_first, pace_t0;
    uint64_t rga_sum_ns, rga_max_ns, dma_sum_ns, dma_max_ns;
    uint64_t grabbed, read_err, rga_err, dma_err, err, late;
    int dma_streak;
    int check_done;
    FILE *csv;

    /* lifecycle */
    pthread_t tid;
    int started;
    volatile int finished;
    volatile int dead;
    int rc;
} Cam;

/* device access */
static volatile uint32_t *g_reg;
static int g_memfd = -1;
static void *g_reg_map = MAP_FAILED;
static inline void wr(uint32_t off, uint32_t v) { g_reg[off >> 2] = v; }
static inline uint32_t rd(uint32_t off) { return g_reg[off >> 2]; }

/* shared display state (guarded by g_door_lock for the doorbell/commit registers) */
static Options g_opt;
static Cam g_cams[MAX_CAMS];
static int g_ncams;
static uint32_t g_fb_base, g_fb_slot, g_done_base, g_seq, g_newfr0, g_uf0;
static uint32_t g_commit_fid;       /* global commit counter (guarded by g_door_lock) */
static pthread_mutex_t g_door_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile sig_atomic_t g_stop;
static uint64_t g_t_start, g_last_print_ns;

/* dump-slot0 state and buffer (960x540 RGB565: 1036800 bytes) */
static int s_dump_slot0_count = 0;
static uint8_t s_dump_slot0_buf[960 * 540 * 2];

static void on_signal(int sig) { (void)sig; g_stop = 1; }

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static double ns_to_ms(uint64_t ns) { return (double)ns / 1e6; }

static void dump_regs(void)
{
    uint32_t o;
    printf("!! doorbell timeout\n");
    for (o = 0x1C0; o <= 0x1EC; o += 4) printf("  0x%03X=0x%08X\n", o, rd(o));
    for (o = 0x800; o <= 0x830; o += 4) printf("  0x%03X=0x%08X\n", o, rd(o));
}

static uint32_t done_rel(void) { return rd(R_DONE) - g_done_base; }

/* wait until outstanding doorbells < n (n=0 => wait for all queued by us);
 * caller must hold g_door_lock */
static int wait_pending(uint32_t n)
{
    uint64_t t0 = now_ns();
    while ((uint32_t)(g_seq - done_rel()) > n) {
        if (g_stop) return -1;
        if (now_ns() - t0 >= DMA_TIMEOUT_NS) return -1;
    }
    return 0;
}

/* ---------------- CMA / dma-heap buffers ---------------- */

/* physical contiguous & <4GB check via /proc/self/pagemap */
static int check_phys_range(void *va, size_t len, long ps, uint64_t *out_pa, const char *name)
{
    int pfd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    size_t npages = (len + (size_t)ps - 1) / (size_t)ps, k;
    uint64_t first = 0;

    if (pfd < 0) { perror("/proc/self/pagemap"); return -1; }
    for (k = 0; k < npages; k++) {
        uint64_t e = 0, pfn, pa;
        off_t off = (off_t)(((uintptr_t)va + k * (uint64_t)ps) / (uint64_t)ps) * 8;
        if (pread(pfd, &e, 8, off) != 8) {
            fprintf(stderr, "%s page %zu: pagemap read failed\n", name, k); close(pfd); return -1;
        }
        pfn = e & ((1ULL << 55) - 1);
        if (!(e & (1ULL << 63)) || pfn == 0) {
            fprintf(stderr, "%s page %zu: not present\n", name, k); close(pfd); return -1;
        }
        pa = pfn * (uint64_t)ps;
        if (k == 0) first = pa;
        else if (pa != first + k * (uint64_t)ps) {
            fprintf(stderr, "%s page %zu: PFN not contiguous\n", name, k); close(pfd); return -1;
        }
    }
    close(pfd);
    if (first + len > FOUR_G) {
        fprintf(stderr, "%s: above 4GB 0x%llx\n", name, (unsigned long long)(first + len));
        return -1;
    }
    if (out_pa) *out_pa = first;
    return 0;
}

static int alloc_dma_buf(const char *name, size_t len, int *out_fd, void **out_va, uint64_t *out_pa)
{
    char path[128];
    int hfd;
    long ps = sysconf(_SC_PAGESIZE);
    struct dma_heap_allocation_data data;
    void *va;

    if (ps <= 0) { perror("sysconf(_SC_PAGESIZE)"); return -1; }
    snprintf(path, sizeof(path), "/dev/dma_heap/cma");
    hfd = open(path, O_RDWR | O_CLOEXEC);
    if (hfd < 0) { perror(path); return -1; }
    memset(&data, 0, sizeof(data));
    data.len = (len + 4095u) & ~(uint64_t)4095u;
    data.fd_flags = O_RDWR | O_CLOEXEC;
    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) {
        perror("DMA_HEAP_IOCTL_ALLOC"); close(hfd); return -1;
    }
    close(hfd);
    va = mmap(NULL, (size_t)data.len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
              (int)data.fd, 0);
    if (va == MAP_FAILED) { perror("mmap (dma-heap)"); close((int)data.fd); return -1; }
    if (check_phys_range(va, (size_t)data.len, ps, out_pa, name) < 0) {
        munmap(va, (size_t)data.len); close((int)data.fd); return -1;
    }
    *out_fd = (int)data.fd;
    *out_va = va;
    return 0;
}

/* ---------------- video file probing ---------------- */

static uint32_t read_u32_be(const uint8_t *b)
{
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}

static uint64_t read_u64_be(const uint8_t *b)
{
    return ((uint64_t)read_u32_be(b) << 32) | (uint64_t)read_u32_be(b + 4);
}

static uint16_t read_u16_be(const uint8_t *b)
{
    return ((uint16_t)b[0] << 8) | (uint16_t)b[1];
}

static int scan_mp4_boxes(FILE *fp, int64_t start_off, int64_t end_off, int depth,
                         int *out_codec, int *out_w, int *out_h, char *out_fmt)
{
    int64_t cur = start_off;
    uint8_t hdr[16];

    if (depth > 10) return -1;

    while (cur + 8 <= end_off) {
        if (fseeko(fp, cur, SEEK_SET) != 0) return -1;
        if (fread(hdr, 1, 8, fp) != 8) return -1;

        uint64_t box_sz = read_u32_be(hdr);
        int64_t hdr_len = 8;
        if (box_sz == 1) {
            if (fread(hdr + 8, 1, 8, fp) != 8) return -1;
            box_sz = read_u64_be(hdr + 8);
            hdr_len = 16;
        } else if (box_sz == 0) {
            box_sz = (uint64_t)(end_off - cur);
        }

        if (box_sz < (uint64_t)hdr_len || cur + (int64_t)box_sz > end_off) {
            break;
        }

        char type[5];
        memcpy(type, hdr + 4, 4);
        type[4] = '\0';

        int64_t box_data_start = cur + hdr_len;
        int64_t box_data_end = cur + (int64_t)box_sz;

        if (!memcmp(type, "moov", 4) || !memcmp(type, "trak", 4) ||
            !memcmp(type, "mdia", 4) || !memcmp(type, "minf", 4) ||
            !memcmp(type, "stbl", 4)) {
            if (scan_mp4_boxes(fp, box_data_start, box_data_end, depth + 1,
                               out_codec, out_w, out_h, out_fmt) == 0) {
                return 0;
            }
        } else if (!memcmp(type, "stsd", 4)) {
            if (box_sz >= 16) {
                uint8_t stsd_hdr[8];
                if (fread(stsd_hdr, 1, 8, fp) == 8) {
                    uint32_t entry_count = read_u32_be(stsd_hdr + 4);
                    int64_t entry_pos = box_data_start + 8;
                    for (uint32_t i = 0; i < entry_count && entry_pos + 8 <= box_data_end; i++) {
                        if (fseeko(fp, entry_pos, SEEK_SET) != 0) break;
                        uint8_t ehdr[8];
                        if (fread(ehdr, 1, 8, fp) != 8) break;
                        uint32_t esz = read_u32_be(ehdr);
                        if (esz < 8) break;

                        char eformat[5];
                        memcpy(eformat, ehdr + 4, 4);
                        eformat[4] = '\0';
                        if (out_fmt && out_fmt[0] == '\0') {
                            memcpy(out_fmt, eformat, 5);
                        }

                        int c = CODEC_UNKNOWN;
                        if (!memcmp(eformat, "avc1", 4) || !memcmp(eformat, "avc3", 4)) {
                            c = CODEC_H264;
                        } else if (!memcmp(eformat, "hvc1", 4) || !memcmp(eformat, "hev1", 4)) {
                            c = CODEC_H265;
                        }

                        if (c != CODEC_UNKNOWN && esz >= 36) {
                            uint8_t vdata[28];
                            if (fread(vdata, 1, 28, fp) == 28) {
                                int w = (int)read_u16_be(vdata + 24);
                                int h = (int)read_u16_be(vdata + 26);
                                if (w > 0 && h > 0) {
                                    *out_codec = c;
                                    *out_w = w;
                                    *out_h = h;
                                    return 0;
                                }
                            }
                        }
                        entry_pos += esz;
                    }
                }
            }
        }

        cur = box_data_end;
    }

    return -1;
}

static int probe_video_file(const char *path, int *out_codec, int *out_w, int *out_h)
{
    char last_fmt[8];
    memset(last_fmt, 0, sizeof(last_fmt));
    *out_codec = CODEC_UNKNOWN;
    *out_w = 0;
    *out_h = 0;

    FILE *fp = fopen(path, "rb");
    if (fp) {
        if (fseeko(fp, 0, SEEK_END) == 0) {
            int64_t fsz = ftello(fp);
            if (fsz > 0) {
                if (scan_mp4_boxes(fp, 0, fsz, 0, out_codec, out_w, out_h, last_fmt) == 0) {
                    fclose(fp);
                    return 0;
                }
            }
        }
        fclose(fp);
    }

    /* Fallback: try gst-discoverer-1.0 */
    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "gst-discoverer-1.0 \"%s\" 2>/dev/null", path);
    FILE *pfp = popen(cmd, "r");
    if (pfp) {
        char line[512];
        int w = 0, h = 0, codec = CODEC_UNKNOWN;
        while (fgets(line, sizeof(line), pfp)) {
            if (strstr(line, "video/x-h264") || strstr(line, "H.264")) {
                codec = CODEC_H264;
            } else if (strstr(line, "video/x-h265") || strstr(line, "H.265") || strstr(line, "HEVC")) {
                codec = CODEC_H265;
            }
            char *pw = strstr(line, "Width: ");
            if (pw) {
                int val = atoi(pw + 7);
                if (val > 0) w = val;
            }
            char *ph = strstr(line, "Height: ");
            if (ph) {
                int val = atoi(ph + 8);
                if (val > 0) h = val;
            }
        }
        pclose(pfp);
        if (codec != CODEC_UNKNOWN && w > 0 && h > 0) {
            *out_codec = codec;
            *out_w = w;
            *out_h = h;
            return 0;
        }
    }

    if (last_fmt[0] != '\0') {
        fprintf(stderr, "error: file '%s': unsupported video format '%.4s' (only H.264/H.265 supported)\n",
                path, last_fmt);
    } else {
        fprintf(stderr, "error: file '%s': unable to determine video codec/dimensions\n", path);
    }
    return -1;
}

static int probe_video_codec(const char *path)
{
    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "gst-discoverer-1.0 \"%s\" 2>/dev/null", path);
    FILE *pfp = popen(cmd, "r");
    if (!pfp) return CODEC_H265;
    char line[512];
    int is_h264 = 0;
    while (fgets(line, sizeof(line), pfp)) {
        if (strcasestr(line, "H.264")) {
            is_h264 = 1;
            break;
        }
    }
    pclose(pfp);
    return is_h264 ? CODEC_H264 : CODEC_H265;
}

static int probe_png(FILE *fp, int *w, int *h)
{
    uint8_t hdr[24];
    if (fseek(fp, 0, SEEK_SET) != 0) return -1;
    if (fread(hdr, 1, 24, fp) != 24) return -1;
    if (memcmp(hdr, "\x89PNG\r\n\x1a\n", 8) != 0) return -1;
    if (memcmp(hdr + 12, "IHDR", 4) != 0) return -1;
    *w = (int)((hdr[16] << 24) | (hdr[17] << 16) | (hdr[18] << 8) | hdr[19]);
    *h = (int)((hdr[20] << 24) | (hdr[21] << 16) | (hdr[22] << 8) | hdr[23]);
    return (*w > 0 && *h > 0) ? 0 : -1;
}

static int probe_bmp(FILE *fp, int *w, int *h)
{
    uint8_t hdr[26];
    if (fseek(fp, 0, SEEK_SET) != 0) return -1;
    if (fread(hdr, 1, 26, fp) != 26) return -1;
    if (hdr[0] != 'B' || hdr[1] != 'M') return -1;
    int32_t width = (int32_t)(hdr[18] | (hdr[19] << 8) | (hdr[20] << 16) | (hdr[21] << 24));
    int32_t height = (int32_t)(hdr[22] | (hdr[23] << 8) | (hdr[24] << 16) | (hdr[25] << 24));
    if (height < 0) height = -height;
    if (width <= 0 || height <= 0) return -1;
    *w = (int)width;
    *h = (int)height;
    return 0;
}

static int probe_jpeg(FILE *fp, int *w, int *h)
{
    uint8_t b[8];
    if (fseek(fp, 0, SEEK_SET) != 0) return -1;
    if (fread(b, 1, 2, fp) != 2 || b[0] != 0xFF || b[1] != 0xD8) return -1;
    while (!feof(fp)) {
        int c;
        do {
            c = fgetc(fp);
            if (c == EOF) return -1;
        } while (c != 0xFF);
        do {
            c = fgetc(fp);
            if (c == EOF) return -1;
        } while (c == 0xFF);
        uint8_t marker = (uint8_t)c;
        if (marker == 0xD9 || marker == 0xDA) return -1; /* EOI or SOS */
        if (fread(b, 1, 2, fp) != 2) return -1;
        uint16_t len = (uint16_t)((b[0] << 8) | b[1]);
        if (len < 2) return -1;
        if ((marker >= 0xC0 && marker <= 0xC3) ||
            (marker >= 0xC5 && marker <= 0xC7) ||
            (marker >= 0xC9 && marker <= 0xCB) ||
            (marker >= 0xCD && marker <= 0xCF)) {
            if (fread(b, 1, 5, fp) != 5) return -1;
            *h = (int)((b[1] << 8) | b[2]);
            *w = (int)((b[3] << 8) | b[4]);
            return (*w > 0 && *h > 0) ? 0 : -1;
        }
        if (fseek(fp, (long)len - 2, SEEK_CUR) != 0) return -1;
    }
    return -1;
}

static int probe_image_file(const char *path, int *out_w, int *out_h)
{
    FILE *fp = fopen(path, "rb");
    if (fp) {
        if (probe_png(fp, out_w, out_h) == 0) { fclose(fp); return 0; }
        if (probe_bmp(fp, out_w, out_h) == 0) { fclose(fp); return 0; }
        if (probe_jpeg(fp, out_w, out_h) == 0) { fclose(fp); return 0; }
        fclose(fp);
    }
    /* Fallback: gst-discoverer-1.0 */
    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "gst-discoverer-1.0 \"%s\" 2>/dev/null", path);
    FILE *pfp = popen(cmd, "r");
    if (pfp) {
        char line[512];
        int w = 0, h = 0;
        while (fgets(line, sizeof(line), pfp)) {
            char *pw = strstr(line, "Width: ");
            if (pw) { int v = atoi(pw + 7); if (v > 0) w = v; }
            char *ph = strstr(line, "Height: ");
            if (ph) { int v = atoi(ph + 8); if (v > 0) h = v; }
        }
        pclose(pfp);
        if (w > 0 && h > 0) {
            *out_w = w;
            *out_h = h;
            return 0;
        }
    }
    return -1;
}

/* ---------------- gst pipeline child ---------------- */

static int gst_open(Cam *c)
{
    int pfd[2];
    posix_spawn_file_actions_t fa;
    char caps[160], devarg[160], nbuf[64], locarg[540];
    char cmdline[1024];
    char *argv[32];
    int n = 0, spawn_rc;
    size_t cl = 0;

    if (pipe2(pfd, O_CLOEXEC) < 0) { perror("pipe2"); return -1; }

    if (c->is_video) {
        snprintf(locarg, sizeof(locarg), "location=%s", c->dev);
        argv[n++] = "gst-launch-1.0";
        argv[n++] = "-q";
        argv[n++] = "filesrc";
        argv[n++] = locarg;
        argv[n++] = "!";
        argv[n++] = "qtdemux";
        argv[n++] = "!";
        if (c->codec == CODEC_H265) {
            argv[n++] = "h265parse";
            argv[n++] = "config-interval=-1";
            argv[n++] = "!";
            argv[n++] = "video/x-h265,stream-format=byte-stream,alignment=au";
        } else {
            argv[n++] = "h264parse";
            argv[n++] = "config-interval=-1";
            argv[n++] = "!";
            argv[n++] = "video/x-h264,stream-format=byte-stream,alignment=au";
        }
        argv[n++] = "!";
        argv[n++] = "fdsink";
        argv[n++] = "fd=1";
        argv[n] = NULL;
    } else if (c->is_still) {
        snprintf(locarg, sizeof(locarg), "location=%s", c->dev);
        argv[n++] = "gst-launch-1.0";
        argv[n++] = "-q";
        argv[n++] = "filesrc";
        argv[n++] = locarg;
        argv[n++] = "!";
        argv[n++] = "decodebin";
        argv[n++] = "!";
        argv[n++] = "videoconvert";
        argv[n++] = "!";
        argv[n++] = "video/x-raw,format=NV12";
        argv[n++] = "!";
        argv[n++] = "fdsink";
        argv[n++] = "fd=1";
        argv[n] = NULL;
    } else if (c->is_file) {
        snprintf(locarg, sizeof(locarg), "location=%s", c->dev);
        argv[n++] = "gst-launch-1.0";
        argv[n++] = "-q";
        argv[n++] = "filesrc";
        argv[n++] = locarg;
        argv[n++] = "!";
        argv[n++] = "qtdemux";
        argv[n++] = "!";
        if (c->codec == CODEC_H265) {
            argv[n++] = "h265parse";
        } else {
            argv[n++] = "h264parse";
        }
        argv[n++] = "!";
        argv[n++] = "mppvideodec";
        argv[n++] = "!";
        argv[n++] = "videoconvert";
        argv[n++] = "!";
        argv[n++] = "video/x-raw,format=NV12";
        argv[n++] = "!";
        argv[n++] = "fdsink";
        argv[n++] = "fd=1";
        argv[n++] = "sync=false";
        argv[n] = NULL;
    } else {
        snprintf(caps, sizeof(caps), "image/jpeg,width=%d,height=%d,framerate=%d/1",
                 c->src_w, c->src_h, c->fps > 0 ? c->fps : 30);
        snprintf(devarg, sizeof(devarg), "device=%s", c->dev);

        argv[n++] = "gst-launch-1.0";
        argv[n++] = "-q";
        argv[n++] = "v4l2src";
        argv[n++] = devarg;
        argv[n++] = "io-mode=4";
        if (c->frames > 0) {
            snprintf(nbuf, sizeof(nbuf), "num-buffers=%d", c->frames);
            argv[n++] = nbuf;
        }
        argv[n++] = "!";
        argv[n++] = caps;
        argv[n++] = "!";
        argv[n++] = "mppjpegdec";
        argv[n++] = "!";
        argv[n++] = "video/x-raw,format=NV12";
        argv[n++] = "!";
        argv[n++] = "fdsink";
        argv[n++] = "fd=1";
        argv[n] = NULL;
    }

    for (n = 0; argv[n]; n++) {
        int w = snprintf(cmdline + cl, sizeof(cmdline) - cl, "%s%s", n ? " " : "", argv[n]);
        if (w < 0 || (size_t)w >= sizeof(cmdline) - cl) break;
        cl += (size_t)w;
    }
    printf("cam%d: gst: %s\n", c->index, cmdline);
    printf("cam%d: gst: stderr -> %s\n", c->index, c->log_path);

    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, c->log_path,
                                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);
    posix_spawn_file_actions_addclose(&fa, pfd[1]);

    spawn_rc = posix_spawnp(&c->pid, "gst-launch-1.0", &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (spawn_rc != 0) {
        fprintf(stderr, "cam%d: posix_spawnp(gst-launch-1.0): %s\n",
                c->index, strerror(spawn_rc));
        close(pfd[0]); close(pfd[1]);
        c->pid = -1;
        return -1;
    }
    close(pfd[1]);
    c->fd = pfd[0];
    printf("cam%d: gst child pid=%d pipe fd=%d\n", c->index, (int)c->pid, c->fd);
    return 0;
}

static void print_gst_log_tail(const char *path)
{
    FILE *fp = fopen(path, "r");
    char buf[4097];
    long sz;
    size_t n;

    if (!fp) { fprintf(stderr, "(no gst log at %s)\n", path); return; }
    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); return; }
    sz = ftell(fp);
    if (sz > 4096) fseek(fp, sz - 4096, SEEK_SET);
    else fseek(fp, 0, SEEK_SET);
    n = fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    buf[n] = '\0';
    fprintf(stderr, "---- gst log tail (%s) ----\n%s\n---- end gst log ----\n", path, buf);
}

/* SIGTERM the child, then reap it (SIGKILL after 2 s) */
static void gst_close(Cam *c)
{
    int st = 0, i, reaped = 0;

    if (c->pid > 0) kill(c->pid, SIGTERM);
    if (c->fd >= 0) { close(c->fd); c->fd = -1; }

    if (c->pid > 0) {
        for (i = 0; i < 100; i++) {
            pid_t w = waitpid(c->pid, &st, WNOHANG);
            if (w == c->pid) { reaped = 1; break; }
            if (w < 0 && errno != EINTR) break;
            usleep(20000);
        }
        if (!reaped) {
            kill(c->pid, SIGKILL);
            waitpid(c->pid, &st, 0);
            printf("cam%d: gst child did not exit on SIGTERM, killed\n", c->index);
        }
        if (reaped && WIFEXITED(st))
            printf("cam%d: gst child exited status=%d\n", c->index, WEXITSTATUS(st));
        else if (reaped && WIFSIGNALED(st))
            printf("cam%d: gst child killed by signal %d\n", c->index, WTERMSIG(st));
        c->pid = -1;
    }
}

/* ---------------- RGA ---------------- */

static int rga_src_init(Cam *c)
{
    im_handle_param_t param;

    memset(&param, 0, sizeof(param));
    param.width = (uint32_t)c->src_w;
    param.height = (uint32_t)c->src_pad_h;
    param.format = RK_FORMAT_YCbCr_420_SP;

    c->src_handle = importbuffer_virtualaddr(c->cap_va, &param);
    if (c->src_handle <= 0) {
        printf("cam%d: note: RGA importbuffer_virtualaddr failed, trying dma-buf fd\n", c->index);
        c->src_handle = importbuffer_fd(c->cap_fd, &param);
        if (c->src_handle <= 0) {
            fprintf(stderr, "cam%d: RGA import of capture buffer failed (va and fd)\n", c->index);
            return -1;
        }
        printf("cam%d: RGA src imported by fd %d (handle=%u)\n",
               c->index, c->cap_fd, (unsigned int)c->src_handle);
    } else {
        printf("cam%d: RGA src imported by virtual address %p (handle=%u)\n",
               c->index, c->cap_va, (unsigned int)c->src_handle);
    }
    return 0;
}

/* NV12 (src_w x src_pad_h, stride = width) -> dst_w x dst_h (NV12 or RGB565) in this camera's CMA
 * buffer; returns the destination buffer index or -1 */
static int rga_convert(Cam *c, uint64_t *rga_ns)
{
    int d = c->dst_idx;
    rga_buffer_t src, dst, pat;
    im_rect srect, drect, prect;
    IM_STATUS st;
    uint64_t t0;

    src = wrapbuffer_handle(c->src_handle, c->src_w, c->src_pad_h,
                            RK_FORMAT_YCbCr_420_SP, c->src_w, c->src_pad_h);
    dst = wrapbuffer_handle(c->dst_handle[d], c->dst_w, c->dst_h, c->dst_format);
    memset(&pat, 0, sizeof(pat));
    srect.x = 0; srect.y = 0; srect.width = c->src_w; srect.height = c->src_h;
    drect.x = 0; drect.y = 0; drect.width = c->dst_w; drect.height = c->dst_h;
    memset(&prect, 0, sizeof(prect));

    if (!c->check_done) {
        IM_STATUS chk = imcheck(src, dst, srect, drect);
        if (chk != IM_STATUS_NOERROR && chk != IM_STATUS_SUCCESS)
            fprintf(stderr, "cam%d: RGA imcheck warning: %s (%d)\n",
                    c->index, imStrError(chk), (int)chk);
        else
            printf("cam%d: RGA imcheck ok: %dx%d (pad %d) NV12 -> %dx%d %s\n",
                   c->index, c->src_w, c->src_h, c->src_pad_h, c->dst_w, c->dst_h,
                   c->dst_format == RK_FORMAT_RGB_565 ? "RGB565" : "NV12");
        c->check_done = 1;
    }

    t0 = now_ns();
    st = improcess(src, dst, pat, srect, drect, prect, 0);
    *rga_ns = now_ns() - t0;
    if (st != IM_STATUS_SUCCESS && st != IM_STATUS_NOERROR) {
        fprintf(stderr, "cam%d: RGA improcess: %s (%d)\n", c->index, imStrError(st), (int)st);
        return -1;
    }
    c->dst_idx = (c->dst_idx + 1) % RGA_DST_BUFS;
    return d;
}

/* ---------------- doorbell (shared, serialised) ---------------- */

/* writes the four doorbell registers in order, one chunk at a time.
 * caller must hold g_door_lock. returns 0 ok, -1 timeout */
static int doorbell_chunks_locked(Cam *c, uint64_t phys)
{
    uint32_t dst = g_fb_base + (uint32_t)c->slot * g_fb_slot;
    size_t off;

    for (off = 0; off < c->frame_bytes; off += DMA_CHUNK) {
        uint32_t len = (uint32_t)(c->frame_bytes - off);
        if (len > DMA_CHUNK) len = DMA_CHUNK;
        if (wait_pending(MAX_OUTSTAND - 1) < 0) return -1;
        wr(R_HOST_LO, (uint32_t)(phys + off));
        wr(R_LEN, len);
        wr(R_DST, dst + (uint32_t)off);
        g_seq++;
        wr(R_SEQ, g_seq);
    }
    if (wait_pending(0) < 0) return -1;
    return 0;
}

/* one frame: doorbell sequence + commit, atomic against all other cameras.
 * returns 0 ok, -1 timeout, -2 stopped */
static int doorbell_frame(Cam *c, uint64_t phys, uint64_t *dma_ns)
{
    uint64_t t0, t1;
    int rc;

    pthread_mutex_lock(&g_door_lock);
    t0 = now_ns();
    rc = doorbell_chunks_locked(c, phys);
    if (rc == 0) {
        /* commit only after the whole frame landed in DDR.
         * The fid is a single global counter, so consecutive commits from different
         * cameras never carry the same frame id. */
        wr(R_FB_COMMIT, (uint32_t)((((g_commit_fid + 1) & 0xFFFFu) << 16) | (uint32_t)c->slot));
        g_commit_fid++;
    }
    t1 = now_ns();
    pthread_mutex_unlock(&g_door_lock);

    if (rc != 0) {
        if (g_stop) return -2;
        dump_regs();
        return -1;
    }
    *dma_ns = t1 - t0;
    c->frames_done++;
    return 0;
}

/* per-camera pacing: fixed cadence from this camera's first committed frame */
static void cam_pace(Cam *c)
{
    int64_t period, deadline;
    uint64_t now;

    if (c->fps <= 0) return;
    period = 1000000000LL / c->fps;
    if (c->frames_done == 0 || c->pace_t0 == 0) c->pace_t0 = now_ns();
    deadline = (int64_t)c->pace_t0 + (int64_t)c->frames_done * period;
    now = now_ns();
    if ((int64_t)now > deadline + period) c->late++;
    if ((int64_t)now > deadline + 3 * period) {
        c->pace_t0 = now - (uint64_t)((int64_t)c->frames_done * period);
        deadline = (int64_t)c->pace_t0 + (int64_t)c->frames_done * period;
    }
    if ((int64_t)now < deadline) {
        struct timespec dl;
        dl.tv_sec = (time_t)(deadline / 1000000000LL);
        dl.tv_nsec = (long)(deadline % 1000000000LL);
        while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &dl, NULL) == EINTR && !g_stop) {
            /* retry */
        }
    }
}

/* ---------------- per-camera setup / teardown ---------------- */

static int cam_alloc(Cam *c)
{
    char tag[64];
    im_handle_param_t param;
    int i;

    if (c->is_video) {
        for (i = 0; i < RGA_DST_BUFS; i++) {
            c->dst_fd[i] = -1;
            c->dst_va[i] = NULL;
            c->dst_handle[i] = 0;
            snprintf(tag, sizeof(tag), "cam%d dst%d", c->index, i);
            if (alloc_dma_buf(tag, c->dst_len, &c->dst_fd[i], &c->dst_va[i], &c->dst_phys[i]) < 0)
                return -1;
            memset(&param, 0, sizeof(param));
            param.width = (uint32_t)c->dst_w;
            param.height = (uint32_t)c->dst_h;
            param.format = (uint32_t)c->dst_format;
            c->dst_handle[i] = importbuffer_fd(c->dst_fd[i], &param);
            if (c->dst_handle[i] <= 0) {
                fprintf(stderr, "cam%d: importbuffer_fd failed for dst %d\n", c->index, i);
                return -1;
            }
        }
        printf("cam%d: %s slot=%d fps=%d dst=%dx%d %s(%zuB) phys[0]=0x%llx phys[1]=0x%llx\n",
               c->index, c->dev, c->slot, c->fps,
               c->dst_w, c->dst_h, c->dst_format == RK_FORMAT_RGB_565 ? "RGB565" : "NV12",
               c->dst_len,
               (unsigned long long)c->dst_phys[0], (unsigned long long)c->dst_phys[1]);
        return 0;
    }

    c->cap_bytes = (size_t)c->src_w * (size_t)c->src_pad_h * 3u / 2u;
    if (c->is_file) {
        printf("cam%d: file %s src=%dx%d pad_h=%d read_bytes=%zu\n",
               c->index, c->dev, c->src_w, c->src_h, c->src_pad_h, c->cap_bytes);
    } else if (c->is_still) {
        printf("cam%d: still %s src=%dx%d pad_h=%d read_bytes=%zu\n",
               c->index, c->dev, c->src_w, c->src_h, c->src_pad_h, c->cap_bytes);
    }
    snprintf(tag, sizeof(tag), "cam%d cap", c->index);
    if (alloc_dma_buf(tag, c->cap_bytes, &c->cap_fd, &c->cap_va, NULL) < 0) return -1;
    c->cap_len = (c->cap_bytes + 4095u) & ~(size_t)4095u;

    for (i = 0; i < RGA_DST_BUFS; i++) {
        c->dst_fd[i] = -1;
        c->dst_va[i] = NULL;
        c->dst_handle[i] = 0;
        snprintf(tag, sizeof(tag), "cam%d dst%d", c->index, i);
        if (alloc_dma_buf(tag, c->dst_len, &c->dst_fd[i], &c->dst_va[i], &c->dst_phys[i]) < 0)
            return -1;
        memset(&param, 0, sizeof(param));
        param.width = (uint32_t)c->dst_w;
        param.height = (uint32_t)c->dst_h;
        param.format = (uint32_t)c->dst_format;
        c->dst_handle[i] = importbuffer_fd(c->dst_fd[i], &param);
        if (c->dst_handle[i] <= 0) {
            fprintf(stderr, "cam%d: importbuffer_fd failed for dst %d\n", c->index, i);
            return -1;
        }
    }
    printf("cam%d: %s slot=%d fps=%d cap=%zuB dst=%dx%d %s(%zuB) phys[0]=0x%llx phys[1]=0x%llx\n",
           c->index, c->dev, c->slot, c->fps, c->cap_bytes,
           c->dst_w, c->dst_h, c->dst_format == RK_FORMAT_RGB_565 ? "RGB565" : "NV12",
           c->dst_len,
           (unsigned long long)c->dst_phys[0], (unsigned long long)c->dst_phys[1]);
    return rga_src_init(c);
}

static void cam_release(Cam *c)
{
    int i;

    gst_close(c);

    if (c->is_video) {
        for (i = 0; i < VDEC_MAX_BUFS; i++) {
            if (c->vdec_src_handles[i] > 0) {
                releasebuffer_handle(c->vdec_src_handles[i]);
                c->vdec_src_handles[i] = 0;
            }
            c->vdec_src_fds[i] = -1;
        }
        vdec_close(&c->vdec);
    }

    if (c->is_still && c->still_nv12) {
        free(c->still_nv12);
        c->still_nv12 = NULL;
    }

    if (c->src_handle > 0) { releasebuffer_handle(c->src_handle); c->src_handle = 0; }
    if (c->cap_va && c->cap_va != MAP_FAILED) munmap(c->cap_va, c->cap_len);
    c->cap_va = NULL;
    if (c->cap_fd >= 0) { close(c->cap_fd); c->cap_fd = -1; }

    for (i = 0; i < RGA_DST_BUFS; i++) {
        if (c->dst_handle[i] > 0) releasebuffer_handle(c->dst_handle[i]);
        c->dst_handle[i] = 0;
        if (c->dst_va[i] && c->dst_va[i] != MAP_FAILED) munmap(c->dst_va[i], c->dst_len);
        c->dst_va[i] = NULL;
        if (c->dst_fd[i] >= 0) close(c->dst_fd[i]);
        c->dst_fd[i] = -1;
    }
    /* the CSV file is closed by main after join, so the stats printer can still
     * fflush it while this thread is running */
}

/* ---------------- pipe reader ---------------- */

/* blocking read of exactly len bytes; 1 = full, 0 = EOF/short, -1 = error */
static inline void update_ch0_nav_time(Cam *c)
{
    if (c->slot == 0) {
        double fps = (c->fps > 0) ? (double)c->fps : 30.0;
        uint64_t frame_seq = (c->frames_loop_count > 0) ? (c->frames_loop_count - 1) : 0;
        adas_set_ch0_time((double)frame_seq / fps);
    }
}

static int read_full(int fd, void *buf, size_t len, size_t *got)
{
    size_t off = 0;

    *got = 0;
    while (off < len) {
        ssize_t n = read(fd, (char *)buf + off, len - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n == 0) { *got = off; return 0; }
        if (errno == EINTR) {
            *got = off;
            if (g_stop) return off == len ? 1 : 0;
            continue;
        }
        fprintf(stderr, "read(gst pipe): %s\n", strerror(errno));
        *got = off;
        return -1;
    }
    *got = off;
    return 1;
}

static int cam_run(Cam *c)
{
    int rc = 0;

    while (!g_stop) {
        uint64_t t_rga = 0, t_dma = 0;
        int dst_idx;

        if (c->is_video) {
            VFrame vf;
            int vr = vdec_get_frame(&c->vdec, c->fd, &vf);
            if (vr != 1) {
                if (g_stop) break;
                if (vr == 0) {
                    if (g_opt.file_once) {
                        printf("cam%d: video playback complete (%llu frames)\n",
                               c->index, (unsigned long long)c->frames_done);
                        rc = 0;
                        break;
                    }
                    if (c->frames_loop_count == 0) {
                        fprintf(stderr, "cam%d: video EOF without decoding any frames in cycle\n", c->index);
                        c->err++;
                        c->read_err++;
                        print_gst_log_tail(c->log_path);
                        rc = 5;
                        break;
                    }
                    gst_close(c);
                    c->frames_loop_count = 0;
                    if (gst_open(c) < 0) {
                        fprintf(stderr, "cam%d: failed to restart gst child for video loop\n", c->index);
                        c->err++;
                        rc = 5;
                        break;
                    }
                    vdec_reset(&c->vdec);
                    continue;
                } else {
                    fprintf(stderr, "cam%d: vdec_get_frame error %d at frame %llu\n",
                            c->index, vr, (unsigned long long)c->frames_done);
                    c->err++;
                    c->read_err++;
                    print_gst_log_tail(c->log_path);
                    rc = 5;
                    break;
                }
            }
            c->grabbed++;
            c->frames_loop_count++;
            update_ch0_nav_time(c);
            if (!c->cap_bytes) {
                c->src_w = (int)vf.width;
                c->src_h = (int)vf.height;
                c->cap_bytes = (size_t)vf.hor_stride * vf.ver_stride * 3u / 2u;
                if (g_opt.npu_model) {
                    qnpu_register(c->slot, c->src_w, c->src_h);
                }
            }

            int d = c->dst_idx;
            rga_buffer_t src, dst, pat;
            im_rect srect, drect, prect;
            IM_STATUS st;
            uint64_t t0;
            rga_buffer_handle_t src_h = 0;

            if (vf.index >= 0 && vf.index < VDEC_MAX_BUFS) {
                if (c->vdec_src_handles[vf.index] > 0 && c->vdec_src_fds[vf.index] == vf.fd) {
                    src_h = c->vdec_src_handles[vf.index];
                } else {
                    im_handle_param_t param;
                    memset(&param, 0, sizeof(param));
                    param.width = vf.width;
                    param.height = vf.height;
                    param.format = RK_FORMAT_YCbCr_420_SP;
                    src_h = importbuffer_fd(vf.fd, &param);
                    if (src_h <= 0) {
                        fprintf(stderr, "cam%d: RGA importbuffer_fd failed for vframe fd %d\n", c->index, vf.fd);
                        vdec_release(&c->vdec, &vf);
                        c->err++;
                        c->rga_err++;
                        continue;
                    }
                    c->vdec_src_handles[vf.index] = src_h;
                    c->vdec_src_fds[vf.index] = vf.fd;
                }
            } else {
                fprintf(stderr, "cam%d: invalid vframe index %d\n", c->index, vf.index);
                vdec_release(&c->vdec, &vf);
                c->err++;
                c->rga_err++;
                continue;
            }

            src = wrapbuffer_handle(src_h, (int)vf.width, (int)vf.height,
                                    RK_FORMAT_YCbCr_420_SP, (int)vf.hor_stride, (int)vf.ver_stride);
            dst = wrapbuffer_handle(c->dst_handle[d], c->dst_w, c->dst_h, c->dst_format);
            memset(&pat, 0, sizeof(pat));
            srect.x = 0; srect.y = 0; srect.width = (int)vf.width; srect.height = (int)vf.height;
            drect.x = 0; drect.y = 0; drect.width = c->dst_w; drect.height = c->dst_h;
            memset(&prect, 0, sizeof(prect));

            if (!c->check_done) {
                IM_STATUS chk = imcheck(src, dst, srect, drect);
                if (chk != IM_STATUS_NOERROR && chk != IM_STATUS_SUCCESS)
                    fprintf(stderr, "cam%d: RGA imcheck warning: %s (%d)\n",
                            c->index, imStrError(chk), (int)chk);
                else
                    printf("cam%d: RGA imcheck ok: %ux%u (stride %ux%u) NV12 -> %dx%d %s\n",
                           c->index, vf.width, vf.height, vf.hor_stride, vf.ver_stride,
                           c->dst_w, c->dst_h,
                           c->dst_format == RK_FORMAT_RGB_565 ? "RGB565" : "NV12");
                c->check_done = 1;
            }

            t0 = now_ns();
            st = improcess(src, dst, pat, srect, drect, prect, 0);
            t_rga = now_ns() - t0;
            if (st != IM_STATUS_SUCCESS && st != IM_STATUS_NOERROR) {
                vdec_release(&c->vdec, &vf);
                fprintf(stderr, "cam%d: RGA improcess: %s (%d)\n", c->index, imStrError(st), (int)st);
                c->err++;
                c->rga_err++;
                continue;
            }
            if (g_opt.npu_model) {
                QnpuSrc nsrc;
                memset(&nsrc, 0, sizeof(nsrc));
                nsrc.handle = (uint32_t)src_h;
                nsrc.fd = vf.fd;
                nsrc.width = (int)vf.width;
                nsrc.height = (int)vf.height;
                nsrc.wstride = (int)vf.hor_stride;
                nsrc.hstride = (int)vf.ver_stride;
                nsrc.format = RK_FORMAT_YCbCr_420_SP;
                nsrc.frame_id = c->frames_done;
                qnpu_offer(c->slot, &nsrc);
            }
            if (g_opt.adas_cfg && c->slot == 0 && (c->frames_done % 6 == 0)) {
                QnpuSrc asrc;
                memset(&asrc, 0, sizeof(asrc));
                asrc.handle = (uint32_t)src_h;
                asrc.fd = vf.fd;
                asrc.width = (int)vf.width;
                asrc.height = (int)vf.height;
                asrc.wstride = (int)vf.hor_stride;
                asrc.hstride = (int)vf.ver_stride;
                asrc.format = RK_FORMAT_YCbCr_420_SP;
                asrc.frame_id = c->frames_done;
                adas_offer(0, &asrc);
            }
            vdec_release(&c->vdec, &vf);
            dst_idx = d;
            c->dst_idx = (c->dst_idx + 1) % RGA_DST_BUFS;
        } else if (c->is_still) {
            dst_idx = rga_convert(c, &t_rga);
            if (dst_idx < 0) {
                c->err++;
                c->rga_err++;
                continue;
            }
            c->grabbed++;
            c->frames_loop_count++;
            update_ch0_nav_time(c);
            if (g_opt.npu_model) {
                QnpuSrc nsrc;
                memset(&nsrc, 0, sizeof(nsrc));
                nsrc.handle = (uint32_t)c->src_handle;
                nsrc.fd = c->cap_fd;
                nsrc.width = c->src_w;
                nsrc.height = c->src_h;
                nsrc.wstride = c->src_w;
                nsrc.hstride = c->src_h;
                nsrc.format = RK_FORMAT_YCbCr_420_SP;
                nsrc.frame_id = c->frames_done;
                qnpu_offer(c->slot, &nsrc);
            }
            if (g_opt.adas_cfg && c->slot == 0 && (c->frames_done % 6 == 0)) {
                QnpuSrc asrc;
                memset(&asrc, 0, sizeof(asrc));
                asrc.handle = (uint32_t)c->src_handle;
                asrc.fd = c->cap_fd;
                asrc.width = c->src_w;
                asrc.height = c->src_h;
                asrc.wstride = c->src_w;
                asrc.hstride = c->src_h;
                asrc.format = RK_FORMAT_YCbCr_420_SP;
                asrc.frame_id = c->frames_done;
                adas_offer(0, &asrc);
            }
        } else {
            size_t got = 0;
            int r;

            r = read_full(c->fd, c->cap_va, c->cap_bytes, &got);
            if (r != 1) {
                if (g_stop) break;
                if (c->is_file) {
                    if (g_opt.file_once) {
                        printf("cam%d: file playback complete (%llu frames)\n",
                               c->index, (unsigned long long)c->frames_done);
                        rc = 0;
                        break;
                    }
                    /* default: loop playback */
                    if (c->frames_loop_count == 0) {
                        fprintf(stderr, "cam%d: file EOF without decoding any frames in cycle\n", c->index);
                        c->err++;
                        c->read_err++;
                        print_gst_log_tail(c->log_path);
                        rc = 5;
                        break;
                    }
                    /* Restart gst pipeline for next loop cycle */
                    gst_close(c);
                    c->frames_loop_count = 0;
                    if (gst_open(c) < 0) {
                        fprintf(stderr, "cam%d: failed to restart gst child for loop\n", c->index);
                        c->err++;
                        rc = 5;
                        break;
                    }
                    continue;
                } else {
                    if (r == 0)
                        fprintf(stderr, "cam%d: gst EOF at frame %llu (got %zu of %zu bytes)\n",
                                c->index, (unsigned long long)c->frames_done, got, c->cap_bytes);
                    c->err++;
                    c->read_err++;
                    print_gst_log_tail(c->log_path);
                    rc = 5;
                    break;
                }
            }
            c->grabbed++;
            c->frames_loop_count++;
            update_ch0_nav_time(c);

            dst_idx = rga_convert(c, &t_rga);
            if (dst_idx < 0) {
                c->err++;
                c->rga_err++;
                continue;
            }

            if (g_opt.npu_model) {
                if (c->is_file) {
                    QnpuSrc nsrc;
                    memset(&nsrc, 0, sizeof(nsrc));
                    nsrc.handle = (uint32_t)c->src_handle;
                    nsrc.fd = c->cap_fd;
                    nsrc.width = c->src_w;
                    nsrc.height = c->src_h;
                    nsrc.wstride = c->src_w;
                    nsrc.hstride = c->src_pad_h;
                    nsrc.format = RK_FORMAT_YCbCr_420_SP;
                    nsrc.frame_id = c->frames_done;
                    qnpu_offer(c->slot, &nsrc);
                } else {
                    QnpuSrc nsrc;
                    memset(&nsrc, 0, sizeof(nsrc));
                    nsrc.handle = (uint32_t)c->src_handle;
                    nsrc.fd = c->cap_fd;
                    nsrc.width = c->src_w;
                    nsrc.height = c->src_h;
                    nsrc.wstride = c->src_w;
                    nsrc.hstride = c->src_h;
                    nsrc.format = RK_FORMAT_YCbCr_420_SP;
                    nsrc.frame_id = c->frames_done;
                    qnpu_offer(c->slot, &nsrc);
                }
            }
            if (g_opt.adas_cfg && c->slot == 0 && (c->frames_done % 6 == 0)) {
                QnpuSrc asrc;
                memset(&asrc, 0, sizeof(asrc));
                asrc.handle = (uint32_t)c->src_handle;
                asrc.fd = c->cap_fd;
                asrc.width = c->src_w;
                asrc.height = c->src_h;
                asrc.wstride = c->src_w;
                asrc.hstride = c->is_file ? c->src_pad_h : c->src_h;
                asrc.format = RK_FORMAT_YCbCr_420_SP;
                asrc.frame_id = c->frames_done;
                adas_offer(0, &asrc);
            }
        }

        /* dump-slot0 export logic: synchronous dump of slot0 DMA buffer after RGA */
        if (c->slot == 0 && g_opt.dump_slot0_n > 0 &&
            s_dump_slot0_count < g_opt.dump_slot0_n &&
            (c->frames_done % (uint64_t)g_opt.dump_slot0_k == 0)) {
            struct dma_buf_sync sync;
            memset(&sync, 0, sizeof(sync));
            sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
            ioctl(c->dst_fd[dst_idx], DMA_BUF_IOCTL_SYNC, &sync);

            size_t src_stride = (size_t)c->dst_w * 2;
            int y;
            for (y = 0; y < 540; y++) {
                memcpy(s_dump_slot0_buf + y * (960 * 2),
                       (const uint8_t *)c->dst_va[dst_idx] + y * src_stride,
                       960 * 2);
            }

            sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
            ioctl(c->dst_fd[dst_idx], DMA_BUF_IOCTL_SYNC, &sync);

            char dpath[64];
            snprintf(dpath, sizeof(dpath), "/tmp/slot0_dump/f%04d.rgb565", s_dump_slot0_count);
            FILE *dfp = fopen(dpath, "wb");
            if (dfp) {
                size_t nw = fwrite(s_dump_slot0_buf, 1, sizeof(s_dump_slot0_buf), dfp);
                fclose(dfp);
                if (nw == sizeof(s_dump_slot0_buf)) {
                    printf("dump slot0 f%04d\n", s_dump_slot0_count);
                } else {
                    fprintf(stderr, "dump slot0 f%04d: partial write %zu bytes\n", s_dump_slot0_count, nw);
                }
            } else {
                perror(dpath);
            }
            s_dump_slot0_count++;
        }

        /* pace outside the doorbell lock so a sleeping camera never blocks others */
        cam_pace(c);

        {
            int dr = doorbell_frame(c, c->dst_phys[dst_idx], &t_dma);
            if (dr == -2) break;                  /* stop requested */
            if (dr < 0) {
                c->err++;
                c->dma_err++;
                c->dma_streak++;
                if (c->dma_streak == DMA_WARN_STREAK)
                    fprintf(stderr, "cam%d: WARNING: %d consecutive doorbell failures "
                            "(continuing)\n", c->index, c->dma_streak);
                if (c->dma_streak >= DMA_DEAD_STREAK) {
                    fprintf(stderr, "cam%d: %d consecutive doorbell failures, camera marked dead\n",
                            c->index, c->dma_streak);
                    rc = 1;
                    c->dead = 1;
                    break;
                }
                continue;
            }
            c->dma_streak = 0;
            update_ch0_nav_time(c);
        }

        if (c->frames_done == 1) c->t_first = now_ns();
        c->rga_sum_ns += t_rga;
        if (t_rga > c->rga_max_ns) c->rga_max_ns = t_rga;
        c->dma_sum_ns += t_dma;
        if (t_dma > c->dma_max_ns) c->dma_max_ns = t_dma;

        if (c->csv) {
            fprintf(c->csv, "%llu,%llu,%zu,%.3f,%.3f\n",
                    (unsigned long long)(c->frames_done - 1),
                    (unsigned long long)((now_ns() - g_t_start) / 1000000ULL),
                    c->cap_bytes, ns_to_ms(t_rga), ns_to_ms(t_dma));
        }

        if (c->frames > 0 && (long long)c->frames_done >= c->frames) break;
    }
    return rc;
}

static void *cam_thread(void *arg)
{
    Cam *c = (Cam *)arg;

    c->rc = 0;
    c->frames_loop_count = 0;
    if (c->is_video) {
        if (vdec_open(&c->vdec, c->codec, g_opt.dec_bufs, "cma") < 0) {
            fprintf(stderr, "cam%d: vdec_open failed\n", c->index);
            c->err++;
            c->rc = 1;
            c->dead = 1;
            c->finished = 1;
            return NULL;
        }
    }
    if (cam_alloc(c) < 0) {
        fprintf(stderr, "cam%d: buffer setup failed, thread exits\n", c->index);
        c->err++;
        c->rc = 1;
        c->dead = 1;
        cam_release(c);
        c->finished = 1;
        return NULL;
    }
    if (gst_open(c) < 0) {
        if (c->is_still) {
            fprintf(stderr, "still: decode failed for %s\n", c->dev);
        }
        c->err++;
        c->rc = 1;
        c->dead = 1;
        cam_release(c);
        c->finished = 1;
        return NULL;
    }

    if (c->is_still) {
        c->still_nv12 = malloc(c->still_bytes);
        if (!c->still_nv12) {
            fprintf(stderr, "cam%d: out of memory allocating still buffer (%zu bytes)\n",
                    c->index, c->still_bytes);
            fprintf(stderr, "still: decode failed for %s\n", c->dev);
            c->err++;
            c->rc = 1;
            c->dead = 1;
            cam_release(c);
            c->finished = 1;
            return NULL;
        }
        size_t got = 0;
        int r = read_full(c->fd, c->still_nv12, c->still_bytes, &got);
        gst_close(c);
        if (r != 1 || got < c->still_bytes) {
            fprintf(stderr, "still: decode failed for %s\n", c->dev);
            free(c->still_nv12);
            c->still_nv12 = NULL;
            c->err++;
            c->rc = 1;
            c->dead = 1;
            cam_release(c);
            c->finished = 1;
            return NULL;
        }
        if (c->cap_va && c->cap_bytes >= c->still_bytes) {
            memcpy(c->cap_va, c->still_nv12, c->still_bytes);
        }
        printf("cam%d: still image %s decoded ok (%dx%d, %zu bytes)\n",
               c->index, c->dev, c->still_w, c->still_h, c->still_bytes);
    }

    c->rc = cam_run(c);
    if (c->rc) c->dead = 1;
    cam_release(c);
    c->finished = 1;
    return NULL;
}

/* ---------------- statistics ---------------- */

static void print_stat(void)
{
    uint64_t now = now_ns(), dt = now - g_last_print_ns;
    char line[320];
    size_t off = 0;
    uint64_t df_total = 0, err_total = 0, late_total = 0;
    int i;

    if (dt == 0) dt = 1;
    for (i = 0; i < g_ncams; i++) {
        Cam *c = &g_cams[i];
        uint64_t df = c->frames_done - c->last_frames;
        int w;
        c->last_frames = c->frames_done;
        df_total += df;
        err_total += c->err;
        late_total += c->late;
        w = snprintf(line + off, sizeof(line) - off, "cam%d=%.1ffps%s ",
                     i, (double)df * 1e9 / (double)dt, c->dead ? "(dead)" : "");
        if (w < 0 || (size_t)w >= sizeof(line) - off) break;
        off += (size_t)w;
    }
    printf("[%6llus] %s| total=%.1ffps err=%llu late=%llu\n",
           (unsigned long long)(now / 1000000000ULL), line,
           (double)df_total * 1e9 / (double)dt,
           (unsigned long long)err_total, (unsigned long long)late_total);
    if (g_opt.npu_model) {
        char nbuf[256];
        qnpu_stats_line(nbuf, sizeof(nbuf));
        printf("npu: %s\n", nbuf);
    }
    if (g_opt.adas_cfg) {
        char abuf[256];
        adas_stats_line(abuf, sizeof(abuf));
        printf("%s\n", abuf);
    }
    g_last_print_ns = now;
    for (i = 0; i < g_ncams; i++) if (g_cams[i].csv) fflush(g_cams[i].csv);
}

static void print_cam_summary(Cam *c)
{
    uint64_t span;
    double avg_fps = 0.0;
    double rga_avg = c->frames_done ? ns_to_ms(c->rga_sum_ns) / (double)c->frames_done : 0.0;
    double dma_avg = c->frames_done ? ns_to_ms(c->dma_sum_ns) / (double)c->frames_done : 0.0;

    span = (c->t_first && now_ns() > c->t_first) ? now_ns() - c->t_first : 0;
    if (c->frames_done > 1 && span) avg_fps = (double)(c->frames_done - 1) * 1e9 / (double)span;

    printf("---- cam%d %s slot=%d%s ----\n", c->index, c->dev, c->slot,
           c->dead ? " DEAD" : "");
    printf("frames=%llu avg_fps=%.1f rga_avg=%.2fms rga_max=%.2fms dma_avg=%.2fms "
           "dma_max=%.2fms err=%llu late=%llu\n",
           (unsigned long long)c->frames_done, avg_fps, rga_avg, ns_to_ms(c->rga_max_ns),
           dma_avg, ns_to_ms(c->dma_max_ns), (unsigned long long)c->err,
           (unsigned long long)c->late);
    printf("errors: read=%llu rga=%llu dma=%llu (frames read=%llu)\n",
           (unsigned long long)c->read_err, (unsigned long long)c->rga_err,
           (unsigned long long)c->dma_err, (unsigned long long)c->grabbed);
}

static void print_summary(void)
{
    uint64_t frames = 0, err = 0, late = 0, read_err = 0, rga_err = 0, dma_err = 0;
    uint64_t rga_sum = 0, dma_sum = 0;
    double avg_fps = 0.0;
    uint64_t span = now_ns() - g_t_start;
    int i;

    for (i = 0; i < g_ncams; i++) {
        Cam *c = &g_cams[i];
        print_cam_summary(c);
        frames += c->frames_done;
        err += c->err;
        late += c->late;
        read_err += c->read_err;
        rga_err += c->rga_err;
        dma_err += c->dma_err;
        rga_sum += c->rga_sum_ns;
        dma_sum += c->dma_sum_ns;
    }
    if (frames > 1 && span) avg_fps = (double)(frames - 1) * 1e9 / (double)span;
    printf("---- total ----\n");
    printf("cams=%d frames=%llu commits=%u avg_fps=%.1f rga_avg=%.2fms dma_avg=%.2fms "
           "late=%llu err=%llu\n",
           g_ncams, (unsigned long long)frames, g_commit_fid, avg_fps,
           frames ? ns_to_ms(rga_sum) / (double)frames : 0.0,
           frames ? ns_to_ms(dma_sum) / (double)frames : 0.0,
           (unsigned long long)late, (unsigned long long)err);
    printf("errors: read=%llu rga=%llu dma=%llu\n",
           (unsigned long long)read_err, (unsigned long long)rga_err,
           (unsigned long long)dma_err);
    printf("display: newfr=%u uf=%u\n", rd(R_DISP_NEWFR) - g_newfr0, rd(R_DISP_UF) - g_uf0);
}

/* ---------------- command line ---------------- */

static void usage(const char *p)
{
    fprintf(stderr,
        "Usage: %s [options]\n"
        "  --cam <dev>:<slot>[:<fps>]   repeatable (max %d), capture thread per camera\n"
        "  --file <path>:<slot>[:<fps>] repeatable (max %d), playback thread per video file\n"
        "  --video <path>:<slot>[:<fps>] repeatable (max %d), hardware decode video file (MPP+CMA)\n"
        "  --still <path>:<slot>[:<fps>] repeatable (max %d), display still image loop\n"
        "  --dec-bufs N                 decoder external buffer count per video (default 10)\n"
        "  --npu <model.rknn>           enable quad NPU inference with specified model\n"
        "  --npu-weights a,b,c,d        SWRR scheduling weights for 4 channels (default 2,1,1,1)\n"
        "  --npu-conf F                 confidence threshold (default 0.25)\n"
        "  --npu-dump N                 dump N frames per channel to /tmp/qnpu_dump (default 0)\n"
        "  --adas <cfg>                 enable ADAS lane/traffic light assistant (cfg optional)\n"
        "  --nav <path>                 load navigation route (.nav) for autonomous lane change\n"
        "  --file-once                  play video files once and exit (default: loop)\n"
        "  --slot0-rgb565               output RGB565 (stride 1920, 960x540) for slot 0\n"
        "  --dump-slot0 N[:K]           dump N frames from slot0 (every K, def 30) to /tmp/slot0_dump (RGB565 LE: R[15:11], G[10:5], B[4:0])\n"
        "  --dev <path>     single-camera capture node (default /dev/video17)\n"
        "  --slot <0-3>     single-camera display slot (default 2)\n"
        "  --bar1 <hex>     FPGA BAR1 phys address (default f0204000)\n"
        "  --src WxH        capture size (default 1280x720)\n"
        "  --dst WxH        display size (default 1920x1080)\n"
        "  --fps N          target rate per camera/file, 0=unlimited (default 30)\n"
        "  --frames N       frames per camera/file, 0=forever (default 0)\n"
        "  --csv <path>     per-frame CSV (<path>.<slot>.csv when multi-camera)\n"
        "  --gst-log <path> gst stderr log (<path>.<slot>.log when multi-camera)\n"
        "  --help, -h       show this help message\n",
        p, MAX_CAMS, MAX_CAMS, MAX_CAMS, MAX_CAMS);
}

static int parse_size(const char *s, int *w, int *h)
{
    char *end = NULL;
    long v;

    v = strtol(s, &end, 10);
    if (end == s || (*end != 'x' && *end != 'X')) return -1;
    if (v <= 0 || v > 8192) return -1;
    *w = (int)v;
    v = strtol(end + 1, &end, 10);
    if (*end != '\0' || v <= 0 || v > 8192) return -1;
    *h = (int)v;
    return 0;
}

/* <dev>:<slot>[:<fps>] */
static int parse_cam_spec(const char *s, Cam *c)
{
    c->is_file = 0;
    const char *sep = strchr(s, ':');
    char *end = NULL;
    size_t len;
    long v, f;

    if (!sep || sep == s) return -1;
    len = (size_t)(sep - s);
    if (len >= sizeof(c->dev)) return -1;
    memcpy(c->dev, s, len);
    c->dev[len] = '\0';

    v = strtol(sep + 1, &end, 10);
    if (end == sep + 1 || v < 0 || v > 3) return -1;
    c->slot = (int)v;
    c->fps = -1;
    if (*end == ':') {
        const char *fs = end + 1;
        f = strtol(fs, &end, 10);
        if (end == fs || *end != '\0' || f < 0 || f > 1000) return -1;
        c->fps = (int)f;
    } else if (*end != '\0') {
        return -1;
    }
    return 0;
}

/* <path>:<slot>[:<fps>] (path does not contain colons) */
static int parse_file_spec(const char *s, Cam *c)
{
    c->is_file = 1;
    const char *sep = strchr(s, ':');
    char *end = NULL;
    size_t len;
    long v, f;

    if (!sep || sep == s) return -1;
    len = (size_t)(sep - s);
    if (len >= sizeof(c->dev)) return -1;
    memcpy(c->dev, s, len);
    c->dev[len] = '\0';

    v = strtol(sep + 1, &end, 10);
    if (end == sep + 1 || v < 0 || v > 3) return -1;
    c->slot = (int)v;
    c->fps = -1;
    if (*end == ':') {
        const char *fs = end + 1;
        f = strtol(fs, &end, 10);
        if (end == fs || *end != '\0' || f < 0 || f > 1000) return -1;
        c->fps = (int)f;
    } else if (*end != '\0') {
        return -1;
    }
    return 0;
}

/* <path>:<slot>[:<fps>] (path does not contain colons) */
static int parse_video_spec(const char *s, Cam *c)
{
    c->is_video = 1;
    c->is_file = 0;
    const char *sep = strchr(s, ':');
    char *end = NULL;
    size_t len;
    long v, f;

    if (!sep || sep == s) return -1;
    len = (size_t)(sep - s);
    if (len >= sizeof(c->dev)) return -1;
    memcpy(c->dev, s, len);
    c->dev[len] = '\0';

    v = strtol(sep + 1, &end, 10);
    if (end == sep + 1 || v < 0 || v > 3) return -1;
    c->slot = (int)v;
    c->fps = -1;
    if (*end == ':') {
        const char *fs = end + 1;
        f = strtol(fs, &end, 10);
        if (end == fs || *end != '\0' || f < 0 || f > 1000) return -1;
        c->fps = (int)f;
    } else if (*end != '\0') {
        return -1;
    }
    return 0;
}

/* <path>:<slot>[:<fps>] (path does not contain colons) */
static int parse_still_spec(const char *s, Cam *c)
{
    c->is_still = 1;
    c->is_video = 0;
    c->is_file = 0;
    const char *sep = strchr(s, ':');
    char *end = NULL;
    size_t len;
    long v, f;

    if (!sep || sep == s) return -1;
    len = (size_t)(sep - s);
    if (len >= sizeof(c->dev)) return -1;
    memcpy(c->dev, s, len);
    c->dev[len] = '\0';

    v = strtol(sep + 1, &end, 10);
    if (end == sep + 1 || v < 0 || v > 3) return -1;
    c->slot = (int)v;
    c->fps = -1;
    if (*end == ':') {
        const char *fs = end + 1;
        f = strtol(fs, &end, 10);
        if (end == fs || *end != '\0' || f < 0 || f > 1000) return -1;
        c->fps = (int)f;
    } else if (*end != '\0') {
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    int i, rc = 0;
    struct sigaction sa;

    memset(&g_opt, 0, sizeof(g_opt));
    memset(g_cams, 0, sizeof(g_cams));
    for (i = 0; i < MAX_CAMS; i++) {
        int b;
        g_cams[i].index = i;
        g_cams[i].is_file = 0;
        g_cams[i].is_video = 0;
        g_cams[i].is_still = 0;
        g_cams[i].still_nv12 = NULL;
        g_cams[i].still_bytes = 0;
        g_cams[i].still_w = 0;
        g_cams[i].still_h = 0;
        g_cams[i].fd = -1;
        g_cams[i].pid = -1;
        g_cams[i].cap_fd = -1;
        g_cams[i].dst_fd[0] = -1;
        g_cams[i].dst_fd[1] = -1;
        g_cams[i].fps = -1;
        g_cams[i].slot = -1;
        g_cams[i].codec = CODEC_UNKNOWN;
        g_cams[i].dst_format = RK_FORMAT_YCbCr_420_SP;
        g_cams[i].src_pad_h = 0;
        g_cams[i].cap_bytes = 0;
        for (b = 0; b < VDEC_MAX_BUFS; b++) {
            g_cams[i].vdec_src_handles[b] = 0;
            g_cams[i].vdec_src_fds[b] = -1;
        }
    }

    g_opt.dev = "/dev/video17";
    g_opt.bar1 = 0xf0204000u;
    g_opt.slot = 2;
    g_opt.src_w = 1280; g_opt.src_h = 720;
    g_opt.dst_w = 1920; g_opt.dst_h = 1080;
    g_opt.fps = 30;
    g_opt.frames = 0;
    g_opt.gst_log = "/tmp/usb_feed_gst.log";
    g_opt.dec_bufs = 10;
    g_opt.npu_model = NULL;
    g_opt.adas_cfg = NULL;
    g_opt.nav_path = NULL;
    g_opt.npu_weights[0] = 2;
    g_opt.npu_weights[1] = 1;
    g_opt.npu_weights[2] = 1;
    g_opt.npu_weights[3] = 1;
    g_opt.npu_conf = 0.25f;
    g_opt.npu_dump = 0;
    g_opt.dump_slot0_n = 0;
    g_opt.dump_slot0_k = 30;

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--cam") && i + 1 < argc) {
            if (g_ncams >= MAX_CAMS) {
                fprintf(stderr, "--cam: at most %d channels total\n", MAX_CAMS);
                return 2;
            }
            if (parse_cam_spec(argv[++i], &g_cams[g_ncams]) < 0) {
                fprintf(stderr, "bad --cam '%s' (want <dev>:<slot>[:<fps>], slot 0..3)\n", argv[i]);
                usage(argv[0]);
                return 2;
            }
            g_ncams++;
        }
        else if (!strcmp(a, "--file") && i + 1 < argc) {
            if (g_ncams >= MAX_CAMS) {
                fprintf(stderr, "--file: at most %d channels total\n", MAX_CAMS);
                return 2;
            }
            if (parse_file_spec(argv[++i], &g_cams[g_ncams]) < 0) {
                fprintf(stderr, "bad --file '%s' (want <path>:<slot>[:<fps>], slot 0..3)\n", argv[i]);
                usage(argv[0]);
                return 2;
            }
            g_ncams++;
        }
        else if (!strcmp(a, "--video") && i + 1 < argc) {
            if (g_ncams >= MAX_CAMS) {
                fprintf(stderr, "--video: at most %d channels total\n", MAX_CAMS);
                return 2;
            }
            if (parse_video_spec(argv[++i], &g_cams[g_ncams]) < 0) {
                fprintf(stderr, "bad --video '%s' (want <path>:<slot>[:<fps>], slot 0..3)\n", argv[i]);
                usage(argv[0]);
                return 2;
            }
            g_ncams++;
        }
        else if (!strcmp(a, "--still") && i + 1 < argc) {
            if (g_ncams >= MAX_CAMS) {
                fprintf(stderr, "--still: at most %d channels total\n", MAX_CAMS);
                return 2;
            }
            if (parse_still_spec(argv[++i], &g_cams[g_ncams]) < 0) {
                fprintf(stderr, "bad --still '%s' (want <path>:<slot>[:<fps>], slot 0..3)\n", argv[i]);
                usage(argv[0]);
                return 2;
            }
            g_ncams++;
        }
        else if (!strcmp(a, "--dec-bufs") && i + 1 < argc) {
            g_opt.dec_bufs = (int)strtol(argv[++i], NULL, 0);
            if (g_opt.dec_bufs <= 0 || g_opt.dec_bufs > VDEC_MAX_BUFS) {
                fprintf(stderr, "--dec-bufs must be 1..%d\n", VDEC_MAX_BUFS);
                return 2;
            }
        }
        else if (!strcmp(a, "--npu") && i + 1 < argc) g_opt.npu_model = argv[++i];
        else if (!strcmp(a, "--adas") && i + 1 < argc) g_opt.adas_cfg = argv[++i];
        else if (!strcmp(a, "--nav") && i + 1 < argc) g_opt.nav_path = argv[++i];
        else if (!strcmp(a, "--npu-weights") && i + 1 < argc) {
            if (sscanf(argv[++i], "%d,%d,%d,%d", &g_opt.npu_weights[0], &g_opt.npu_weights[1],
                       &g_opt.npu_weights[2], &g_opt.npu_weights[3]) != 4) {
                fprintf(stderr, "bad --npu-weights (want a,b,c,d)\n");
                return 2;
            }
        }
        else if (!strcmp(a, "--npu-conf") && i + 1 < argc) g_opt.npu_conf = (float)atof(argv[++i]);
        else if (!strcmp(a, "--npu-dump") && i + 1 < argc) g_opt.npu_dump = (int)strtol(argv[++i], NULL, 0);
        else if (!strcmp(a, "--file-once")) g_opt.file_once = 1;
        else if (!strcmp(a, "--slot0-rgb565")) g_opt.slot0_rgb565 = 1;
        else if (!strcmp(a, "--dump-slot0") && i + 1 < argc) {
            char *end = NULL;
            long n = strtol(argv[++i], &end, 10);
            if (n <= 0) {
                fprintf(stderr, "bad --dump-slot0 (want N > 0)\n");
                return 2;
            }
            g_opt.dump_slot0_n = (int)n;
            g_opt.dump_slot0_k = 30;
            if (*end == ':') {
                long k = strtol(end + 1, &end, 10);
                if (k <= 0 || *end != '\0') {
                    fprintf(stderr, "bad --dump-slot0 (want N[:K] with K > 0)\n");
                    return 2;
                }
                g_opt.dump_slot0_k = (int)k;
            } else if (*end != '\0') {
                fprintf(stderr, "bad --dump-slot0 (want N[:K])\n");
                return 2;
            }
        }
        else if (!strcmp(a, "--help") || !strcmp(a, "-h")) { usage(argv[0]); return 0; }
        else if (!strcmp(a, "--dev") && i + 1 < argc) g_opt.dev = argv[++i];
        else if (!strcmp(a, "--bar1") && i + 1 < argc) g_opt.bar1 = (uint32_t)strtoul(argv[++i], NULL, 16);
        else if (!strcmp(a, "--slot") && i + 1 < argc) g_opt.slot = (int)strtol(argv[++i], NULL, 0);
        else if (!strcmp(a, "--src") && i + 1 < argc) {
            if (parse_size(argv[++i], &g_opt.src_w, &g_opt.src_h) < 0) {
                fprintf(stderr, "bad --src (want WxH)\n"); return 2;
            }
        }
        else if (!strcmp(a, "--dst") && i + 1 < argc) {
            if (parse_size(argv[++i], &g_opt.dst_w, &g_opt.dst_h) < 0) {
                fprintf(stderr, "bad --dst (want WxH)\n"); return 2;
            }
        }
        else if (!strcmp(a, "--fps") && i + 1 < argc) g_opt.fps = (int)strtol(argv[++i], NULL, 0);
        else if (!strcmp(a, "--frames") && i + 1 < argc) g_opt.frames = strtoll(argv[++i], NULL, 0);
        else if (!strcmp(a, "--csv") && i + 1 < argc) g_opt.csv = argv[++i];
        else if (!strcmp(a, "--gst-log") && i + 1 < argc) g_opt.gst_log = argv[++i];
        else { fprintf(stderr, "unknown option: %s\n", a); usage(argv[0]); return 2; }
    }

    if (g_opt.slot < 0 || g_opt.slot > 3) { fprintf(stderr, "--slot must be 0..3\n"); return 2; }
    if (g_opt.fps < 0) { fprintf(stderr, "--fps must be >= 0\n"); return 2; }
    if (g_opt.frames < 0) { fprintf(stderr, "--frames must be >= 0\n"); return 2; }
    if ((g_opt.dst_w & 1) || (g_opt.dst_h & 1) || (g_opt.src_w & 1) || (g_opt.src_h & 1)) {
        fprintf(stderr, "width/height must be even\n"); return 2;
    }

    /* single-camera compatibility: --dev/--slot when no --cam or --file was given */
    if (g_ncams == 0) {
        snprintf(g_cams[0].dev, sizeof(g_cams[0].dev), "%s", g_opt.dev);
        g_cams[0].slot = g_opt.slot;
        g_cams[0].fps = -1;
        g_cams[0].is_file = 0;
        g_ncams = 1;
    }

    /* check if any channel uses slot 0 when --slot0-rgb565 is requested */
    int has_slot0 = 0;
    for (i = 0; i < g_ncams; i++) {
        if (g_cams[i].slot == 0) {
            has_slot0 = 1;
            break;
        }
    }
    if (g_opt.slot0_rgb565 && !has_slot0) {
        printf("notice: --slot0-rgb565 specified but no channel is mapped to slot 0, ignoring\n");
    }

    /* resolve per-channel defaults, probe files, check duplicate slot and input */
    for (i = 0; i < g_ncams; i++) {
        Cam *c = &g_cams[i];
        int k;

        if (c->fps < 0) c->fps = g_opt.fps;
        c->frames = (int)(g_opt.frames > 0x7fffffffLL ? 0x7fffffffLL : g_opt.frames);

        if (g_ncams > 1) {
            if (g_opt.csv) snprintf(c->csv_path, sizeof(c->csv_path), "%s.%d.csv", g_opt.csv, c->slot);
            snprintf(c->log_path, sizeof(c->log_path), "%s.%d.log", g_opt.gst_log, c->slot);
        } else {
            if (g_opt.csv) snprintf(c->csv_path, sizeof(c->csv_path), "%s", g_opt.csv);
            snprintf(c->log_path, sizeof(c->log_path), "%s", g_opt.gst_log);
        }

        for (k = 0; k < i; k++) {
            if (!strcmp(g_cams[k].dev, c->dev)) {
                fprintf(stderr, "error: duplicate input %s\n", c->dev);
                return 2;
            }
        }
        for (k = 0; k < i; k++) {
            if (g_cams[k].slot == c->slot) {
                fprintf(stderr, "error: duplicate slot %d for channel %d (%s) and channel %d (%s)\n",
                        c->slot, k, g_cams[k].dev, i, c->dev);
                return 2;
            }
        }

        if (c->is_video) {
            c->codec = probe_video_codec(c->dev);
            c->src_w = 0;
            c->src_h = 0;
            c->src_pad_h = 0;
            c->cap_bytes = 0;
        } else if (c->is_still) {
            int probe_rc = probe_image_file(c->dev, &c->still_w, &c->still_h);
            if (probe_rc < 0 || c->still_w <= 0 || c->still_h <= 0) {
                c->still_w = g_opt.dst_w;
                c->still_h = g_opt.dst_h;
            }
            c->still_w &= ~1;
            c->still_h &= ~1;
            c->src_w = c->still_w;
            c->src_h = c->still_h;
            c->src_pad_h = c->still_h;
            c->still_bytes = (size_t)c->still_w * (size_t)c->still_h * 3u / 2u;
            c->cap_bytes = c->still_bytes;
        } else if (c->is_file) {
            int probe_rc = probe_video_file(c->dev, &c->codec, &c->src_w, &c->src_h);
            if (probe_rc < 0 || c->codec == CODEC_UNKNOWN) {
                fprintf(stderr, "error: file '%s': unable to determine video codec (only H.264 and H.265 supported)\n",
                        c->dev);
                return 2;
            }
            if (c->src_w <= 0 || c->src_h <= 0) {
                fprintf(stderr, "error: file '%s': unable to determine video dimensions\n", c->dev);
                return 2;
            }
            if ((c->src_w & 1) || (c->src_h & 1)) {
                fprintf(stderr, "error: file '%s': dimensions must be even (%dx%d)\n",
                        c->dev, c->src_w, c->src_h);
                return 2;
            }
            c->src_pad_h = (c->src_h + 15) & ~15;
            c->cap_bytes = (size_t)c->src_w * (size_t)c->src_pad_h * 3u / 2u;
        } else {
            c->src_w = g_opt.src_w;
            c->src_h = g_opt.src_h;
            c->src_pad_h = c->src_h;
            c->cap_bytes = (size_t)c->src_w * (size_t)c->src_h * 3u / 2u;
        }

        if (c->slot == 0 && g_opt.slot0_rgb565) {
            c->dst_w = 960;
            c->dst_h = 540;
            c->dst_format = RK_FORMAT_RGB_565;
            c->frame_bytes = 960 * 540 * 2; /* 1036800 bytes, stride 1920 */
        } else {
            c->dst_w = g_opt.dst_w;
            c->dst_h = g_opt.dst_h;
            c->dst_format = RK_FORMAT_YCbCr_420_SP;
            c->frame_bytes = ((size_t)c->dst_w * (size_t)c->dst_h * 3u / 2u + 255u) & ~(size_t)255u;
        }
        c->dst_len = (c->frame_bytes + 4095u) & ~(size_t)4095u;
    }

    g_t_start = now_ns();

    if (g_opt.dump_slot0_n > 0) {
        if (mkdir("/tmp/slot0_dump", 0777) < 0 && errno != EEXIST) {
            perror("mkdir /tmp/slot0_dump");
        }
    }

    /* map BAR1 registers */
    g_memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_memfd < 0) { perror("/dev/mem"); return 1; }
    g_reg_map = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, g_memfd, g_opt.bar1);
    if (g_reg_map == MAP_FAILED) { perror("mmap /dev/mem"); return 1; }
    g_reg = (volatile uint32_t *)g_reg_map;

    {
        uint32_t a = rd(R_MAGIC0), b = rd(R_DRD_MAGIC), c = rd(R_DISP_MAGIC);
        if (a != MAGIC0_VAL || b != DRD_MAGIC_VAL || (c != DISP1_VAL && c != DISP_OSD_VAL)) {
            fprintf(stderr, "magic mismatch: 0x188=0x%08X 0x1E8=0x%08X 0x83C=0x%08X\n", a, b, c);
            return 7;
        }
    }

    if (g_opt.csv) {
        for (i = 0; i < g_ncams; i++) {
            Cam *c = &g_cams[i];
            c->csv = fopen(c->csv_path, "w");
            if (!c->csv) {
                fprintf(stderr, "failed to open CSV %s: %s\n", c->csv_path, strerror(errno));
                rc = 1;
                goto out;
            }
            fprintf(c->csv, "frame,time_ms,src_bytes,rga_ms,dma_ms\n");
            printf("cam%d: csv %s\n", c->index, c->csv_path);
        }
    }

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    /* display init: enable DDR path + display, then set geometry for --dst */
    wr(R_DDR_EN, 1);
    wr(R_DISP_CTRL, rd(R_DISP_CTRL) | 1u);
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
    if (g_fb_base == 0 || g_fb_slot == 0) {
        fprintf(stderr, "unexpected FB_BASE=0x%08X FB_SLOT=0x%08X\n", g_fb_base, g_fb_slot);
        rc = 7;
        goto out;
    }
    for (i = 0; i < g_ncams; i++) {
        if (g_cams[i].frame_bytes > g_fb_slot) {
            fprintf(stderr, "cam%d: frame_bytes %zu > slot %u\n", i, g_cams[i].frame_bytes, g_fb_slot);
            rc = 2;
            goto out;
        }
    }
    wr(R_FB_STRIDE, (uint32_t)g_opt.dst_w);
    wr(R_FB_UVOFF, (uint32_t)((uint32_t)g_opt.dst_w * (uint32_t)g_opt.dst_h));

    printf("bar1=0x%08X fb_base=0x%08X fb_slot=0x%08X dst=%dx%d cams=%d\n",
           g_opt.bar1, g_fb_base, g_fb_slot, g_opt.dst_w, g_opt.dst_h, g_ncams);
    for (i = 0; i < g_ncams; i++) {
        printf("  cam%d: %s -> slot %d (ddr dst 0x%08X) dst=%dx%d %s (%zuB) fps=%d\n",
               i, g_cams[i].dev, g_cams[i].slot,
               g_fb_base + (uint32_t)g_cams[i].slot * g_fb_slot,
               g_cams[i].dst_w, g_cams[i].dst_h,
               g_cams[i].dst_format == RK_FORMAT_RGB_565 ? "RGB565" : "NV12",
               g_cams[i].frame_bytes,
               g_cams[i].fps);
    }

    /* Initialize NPU if requested */
    if (g_opt.npu_model) {
        QnpuCfg ncfg;
        memset(&ncfg, 0, sizeof(ncfg));
        ncfg.model_path = g_opt.npu_model;
        ncfg.weights[0] = g_opt.npu_weights[0];
        ncfg.weights[1] = g_opt.npu_weights[1];
        ncfg.weights[2] = g_opt.npu_weights[2];
        ncfg.weights[3] = g_opt.npu_weights[3];
        ncfg.conf_thres = g_opt.npu_conf;
        ncfg.dump_n = g_opt.npu_dump;
        ncfg.dump_dir = "/tmp/qnpu_dump";
        if (qnpu_init(&ncfg, g_reg) != 0) {
            fprintf(stderr, "qnpu_init failed for model %s\n", g_opt.npu_model);
            rc = 1;
            goto out;
        }
        for (i = 0; i < g_ncams; i++) {
            if (!g_cams[i].is_video) {
                qnpu_register(g_cams[i].slot, g_cams[i].src_w, g_cams[i].src_h);
            }
        }
    }

    /* Initialize ADAS if requested */
    if (g_opt.adas_cfg) {
        if (adas_init(g_reg, g_opt.adas_cfg) != 0) {
            fprintf(stderr, "adas_init failed, continuing without ADAS\n");
            g_opt.adas_cfg = NULL;
        } else if (g_opt.nav_path) {
            adas_set_nav(g_opt.nav_path);
        }
    }

    /* Worker threads must not take SIGINT/SIGTERM: main is the only thread that
     * handles them, so it can kill the gst children and unblock the readers. */
    {
        sigset_t blockset, oldset;
        sigemptyset(&blockset);
        sigaddset(&blockset, SIGINT);
        sigaddset(&blockset, SIGTERM);
        pthread_sigmask(SIG_BLOCK, &blockset, &oldset);

        for (i = 0; i < g_ncams; i++) {
            g_cams[i].started = 0;
            if (pthread_create(&g_cams[i].tid, NULL, cam_thread, &g_cams[i]) != 0) {
                perror("pthread_create");
                fprintf(stderr, "cam%d: thread start failed\n", i);
                g_cams[i].dead = 1;
                g_cams[i].finished = 1;
                g_cams[i].err++;
                continue;
            }
            g_cams[i].started = 1;
        }
        pthread_sigmask(SIG_SETMASK, &oldset, NULL);
    }

    g_last_print_ns = now_ns();
    for (i = 0; i < g_ncams; i++) g_cams[i].last_frames = 0;

    while (!g_stop) {
        int alive = 0;
        struct timespec ts = { 0, 200 * 1000 * 1000 };
        for (i = 0; i < g_ncams; i++) if (!g_cams[i].finished) alive++;
        if (!alive) break;
        nanosleep(&ts, NULL);
        if (now_ns() - g_last_print_ns >= 1000000000ULL) print_stat();
    }

    /* on a signal, tear the pipelines down so the threads' blocking reads return */
    if (g_stop) {
        for (i = 0; i < g_ncams; i++) {
            pid_t pid = g_cams[i].pid;
            if (g_cams[i].started && pid > 0) kill(pid, SIGTERM);
        }
    }

    for (i = 0; i < g_ncams; i++) {
        if (g_cams[i].started) { pthread_join(g_cams[i].tid, NULL); g_cams[i].started = 0; }
    }

    if (g_opt.npu_model) {
        qnpu_stop();
    }
    if (g_opt.adas_cfg) {
        adas_stop();
        g_opt.adas_cfg = NULL;
    }

    print_summary();
    rc = 0;
    for (i = 0; i < g_ncams; i++) if (g_cams[i].rc && !rc) rc = g_cams[i].rc;
    if (g_stop) rc = 0;

out:
    if (g_opt.adas_cfg) {
        adas_stop();
        g_opt.adas_cfg = NULL;
    }
    if (g_opt.npu_model) {
        qnpu_stop();
    }
    for (i = 0; i < g_ncams; i++) {
        if (g_cams[i].csv) { fflush(g_cams[i].csv); fclose(g_cams[i].csv); g_cams[i].csv = NULL; }
    }
    if (g_reg_map != MAP_FAILED) munmap((void *)g_reg_map, 4096);
    g_reg_map = MAP_FAILED;
    if (g_memfd >= 0) close(g_memfd);
    g_memfd = -1;
    return rc;
}
