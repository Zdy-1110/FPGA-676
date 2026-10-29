/*
 * npu_det.c - RK3568: MPP HW HEVC/H.264 decode -> external CMA buffers (dma-heap)
 *   -> FPGA PCIe doorbell DMA into DDR3 frame slots -> display.
 *   + Latest frame mailbox (1-slot) -> NPU thread RGA pre-processing (NV12 -> RGB888).
 * Usage: npu_det <bar1_hex> <input|-> [options]
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
#include <pthread.h>

#include "rk_mpi.h"
#include "rk_mpi_cmd.h"
#include "mpp_buffer.h"
#include "mpp_frame.h"
#include "mpp_packet.h"

#include "im2d.h"
#include "rknn_api.h"
#include "npu_post.h"

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
#define R_OSD_CTRL 0x880
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
    /* NPU options */
    int no_npu;
    int out_zc;
    const char *dump_rgb;
    uint64_t dump_at;
    int have_dump_at;
    const char *model;
    float conf;
    float iou;
    const char *nms;
    const char *csv;
} Options;

typedef struct { uint32_t w, h, hs, vs; size_t buf_size; } Info;

/* Latest frame mailbox item */
typedef struct {
    MppBuffer buf;
    uint64_t frame_id;
    uint32_t hor_stride;
    uint32_t ver_stride;
    uint32_t width;
    uint32_t height;
    int fd;
} FrameMailboxItem;

/* Latest frame mailbox (1-slot) */
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    FrameMailboxItem item;
    int has_frame;
    int stop;
    uint64_t dropped_frames;
} FrameMailbox;

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

/* mailbox & NPU thread state */
static FrameMailbox g_mailbox;
static pthread_t g_npu_tid;
static int g_npu_thread_started;
static int g_npu_fd = -1;
static void *g_npu_va = MAP_FAILED;
static size_t g_npu_buf_len;
static uint64_t g_npu_phys;
static rga_buffer_handle_t g_npu_dst_handle;

/* RKNN & post-process state */
static const char *k_canonical_output_names[9] = {
    "box_s8", "cls_s8", "sum_s8",
    "box_s16", "cls_s16", "sum_s16",
    "box_s32", "cls_s32", "sum_s32"
};
static rknn_context g_rknn_ctx;
static rknn_input_output_num g_io_num;
static rknn_tensor_attr g_input_attrs[1];
static rknn_tensor_attr g_output_attrs[9];
static int g_out_idx_map[9];
static npu_tensor_t g_post_tensors_template[9];
static rknn_tensor_mem *g_zc_input_mem;
static int g_npu_zero_copy_in;
static rknn_tensor_mem *g_zc_output_mems[9];
static npu_post_config_t g_npu_cfg;
static FILE *g_csv_fp;

/* statistics */
static uint64_t g_frames, g_late, g_err, g_dma_sum_ns, g_dma_max_ns, g_wait_ns;
static uint64_t g_last_print_ns, g_last_frames, g_t_first;
static uint64_t g_npu_frames, g_rga_sum_ns, g_rga_max_ns;
static uint64_t g_infer_sum_ns, g_infer_max_ns;
static uint64_t g_get_sum_ns, g_get_max_ns;
static uint64_t g_post_sum_ns, g_post_max_ns;
static uint64_t g_frame_total_sum_ns;
static uint64_t g_last_npu_frames;
static int g_last_num_dets;
static int g_dump_done;
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
        fprintf(stderr, "%s: above 4GB 0x%llx\n", name,
                (unsigned long long)(first + len));
        return -1;
    }
    if (out_pa) *out_pa = first;
    return 0;
}

static int check_phys(int idx, void *va, long ps)
{
    char tag[32];
    snprintf(tag, sizeof(tag), "buf %d", idx);
    return check_phys_range(va, g_buf_len, ps, &g_phys[idx], tag);
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

/* NPU RGB888 buffer allocation in CMA */
static int alloc_npu_buffer(void)
{
    char path[128];
    int hfd;
    long ps = sysconf(_SC_PAGESIZE);
    struct dma_heap_allocation_data data;
    im_handle_param_t dst_param;

    if (ps <= 0) { perror("sysconf(_SC_PAGESIZE)"); return -1; }
    snprintf(path, sizeof(path), "/dev/dma_heap/%s", g_opt.heap);
    hfd = open(path, O_RDWR | O_CLOEXEC);
    if (hfd < 0) { perror(path); return -1; }

    g_npu_buf_len = (960u * 320u * 3u + 4095u) & ~(size_t)4095u;
    memset(&data, 0, sizeof(data));
    data.len = g_npu_buf_len;
    data.fd_flags = O_RDWR | O_CLOEXEC;
    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) {
        perror("DMA_HEAP_IOCTL_ALLOC (NPU buffer)"); close(hfd); return -1;
    }
    close(hfd);
    g_npu_fd = data.fd;

    g_npu_va = mmap(NULL, g_npu_buf_len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, g_npu_fd, 0);
    if (g_npu_va == MAP_FAILED) { perror("mmap (NPU buffer)"); return -1; }

    if (check_phys_range(g_npu_va, g_npu_buf_len, ps, &g_npu_phys, "npu_buf") < 0) {
        munmap(g_npu_va, g_npu_buf_len);
        g_npu_va = MAP_FAILED;
        return -1;
    }

    memset(&dst_param, 0, sizeof(dst_param));
    dst_param.width = 960;
    dst_param.height = 320;
    dst_param.format = RK_FORMAT_RGB_888;
    g_npu_dst_handle = importbuffer_fd(g_npu_fd, &dst_param);
    if (g_npu_dst_handle <= 0) {
        fprintf(stderr, "importbuffer_fd failed for NPU RGB buffer\n");
        return -1;
    }

    printf("allocated NPU RGB888 buffer: 960x320x3 (%zu bytes), fd=%d, phys=0x%llx, handle=%u\n",
           g_npu_buf_len, g_npu_fd, (unsigned long long)g_npu_phys, (unsigned int)g_npu_dst_handle);
    return 0;
}

static int find_output_index(const rknn_tensor_attr *attrs, uint32_t n_attrs, const char *name, int default_idx)
{
    for (uint32_t i = 0; i < n_attrs; i++) {
        if (strcmp(attrs[i].name, name) == 0) return (int)i;
    }
    for (uint32_t i = 0; i < n_attrs; i++) {
        if (strstr(attrs[i].name, name) != NULL) return (int)i;
    }
    if (default_idx >= 0 && default_idx < (int)n_attrs) return default_idx;
    return -1;
}

static int init_rknn(void)
{
    FILE *fp = fopen(g_opt.model, "rb");
    if (!fp) {
        fprintf(stderr, "error: failed to open model file '%s': %s\n", g_opt.model, strerror(errno));
        return -1;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fprintf(stderr, "error: fseek failed on model file '%s'\n", g_opt.model);
        fclose(fp);
        return -1;
    }
    long sz = ftell(fp);
    if (fseek(fp, 0, SEEK_SET) != 0 || sz <= 0) {
        fprintf(stderr, "error: invalid model size (%ld bytes)\n", sz);
        fclose(fp);
        return -1;
    }
    void *model_data = malloc((size_t)sz);
    if (!model_data) {
        fprintf(stderr, "error: failed to allocate %ld bytes for model\n", sz);
        fclose(fp);
        return -1;
    }
    if (fread(model_data, 1, (size_t)sz, fp) != (size_t)sz) {
        fprintf(stderr, "error: failed to read model data\n");
        free(model_data);
        fclose(fp);
        return -1;
    }
    fclose(fp);

    int ret = rknn_init(&g_rknn_ctx, model_data, (uint32_t)sz, 0, NULL);
    free(model_data);
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "error: rknn_init failed (%d)\n", ret);
        return -1;
    }

    memset(&g_io_num, 0, sizeof(g_io_num));
    ret = rknn_query(g_rknn_ctx, RKNN_QUERY_IN_OUT_NUM, &g_io_num, sizeof(g_io_num));
    if (ret != RKNN_SUCC || g_io_num.n_input != 1 || g_io_num.n_output != 9) {
        fprintf(stderr, "error: unexpected model I/O: %u inputs (want 1), %u outputs (want 9)\n",
                g_io_num.n_input, g_io_num.n_output);
        return -1;
    }

    memset(g_input_attrs, 0, sizeof(g_input_attrs));
    g_input_attrs[0].index = 0;
    ret = rknn_query(g_rknn_ctx, RKNN_QUERY_INPUT_ATTR, &g_input_attrs[0], sizeof(rknn_tensor_attr));
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "error: rknn_query(INPUT_ATTR) failed (%d)\n", ret);
        return -1;
    }

    memset(g_output_attrs, 0, sizeof(g_output_attrs));
    for (uint32_t i = 0; i < 9; i++) {
        g_output_attrs[i].index = i;
        ret = rknn_query(g_rknn_ctx, RKNN_QUERY_OUTPUT_ATTR, &g_output_attrs[i], sizeof(rknn_tensor_attr));
        if (ret != RKNN_SUCC) {
            fprintf(stderr, "error: rknn_query(OUTPUT_ATTR) idx %u failed (%d)\n", i, ret);
            return -1;
        }
    }

    /* Zero-copy input setup with dma-buf fd */
    rknn_tensor_attr in_attr = g_input_attrs[0];
    in_attr.type = RKNN_TENSOR_UINT8;
    in_attr.fmt = RKNN_TENSOR_NHWC;
    in_attr.pass_through = 0;

    g_zc_input_mem = rknn_create_mem_from_fd(g_rknn_ctx, g_npu_fd, g_npu_va, (uint32_t)g_npu_buf_len, 0);
    if (g_zc_input_mem) {
        int set_ret = rknn_set_io_mem(g_rknn_ctx, g_zc_input_mem, &in_attr);
        if (set_ret == RKNN_SUCC) {
            g_npu_zero_copy_in = 1;
            printf("NPU input zero-copy enabled (dma-buf fd %d, size %zu)\n", g_npu_fd, g_npu_buf_len);
        } else {
            fprintf(stderr, "warning: rknn_set_io_mem failed (%d), fallback to rknn_inputs_set\n", set_ret);
            rknn_destroy_mem(g_rknn_ctx, g_zc_input_mem);
            g_zc_input_mem = NULL;
            g_npu_zero_copy_in = 0;
        }
    } else {
        fprintf(stderr, "warning: rknn_create_mem_from_fd failed, fallback to rknn_inputs_set\n");
        g_npu_zero_copy_in = 0;
    }

    /* Output setup: --out-zc uses rknn_create_mem + rknn_set_io_mem, default uses rknn_outputs_get */
    if (g_opt.out_zc) {
        for (uint32_t i = 0; i < 9; i++) {
            uint32_t mem_sz = g_output_attrs[i].size_with_stride > g_output_attrs[i].size ?
                              g_output_attrs[i].size_with_stride : g_output_attrs[i].size;
            g_zc_output_mems[i] = rknn_create_mem(g_rknn_ctx, mem_sz);
            if (!g_zc_output_mems[i]) {
                fprintf(stderr, "error: rknn_create_mem failed for output %u (size %u)\n", i, mem_sz);
                return -1;
            }
            ret = rknn_set_io_mem(g_rknn_ctx, g_zc_output_mems[i], &g_output_attrs[i]);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "error: rknn_set_io_mem failed for output %u (%d)\n", i, ret);
                return -1;
            }
        }
    }
    printf("NPU output mode: %s\n",
           g_opt.out_zc ? "Zero-Copy (rknn_create_mem + rknn_set_io_mem)" : "Default (rknn_outputs_get)");

    /* Map 9 canonical tensor outputs and compute strides */
    for (int k = 0; k < 9; k++) {
        int out_idx = find_output_index(g_output_attrs, 9, k_canonical_output_names[k], k);
        if (out_idx < 0) {
            fprintf(stderr, "error: canonical output '%s' not found in model\n", k_canonical_output_names[k]);
            return -1;
        }
        g_out_idx_map[k] = out_idx;
        const rknn_tensor_attr *attr = &g_output_attrs[out_idx];

        if (attr->fmt == RKNN_TENSOR_NCHW) {
            if (attr->n_dims != 4) {
                fprintf(stderr, "error: tensor %s NCHW n_dims=%u != 4\n", attr->name, attr->n_dims);
                return -1;
            }
            uint32_t h = attr->dims[2], w = attr->dims[3];
            g_post_tensors_template[k].n_channels = (int32_t)attr->dims[1];
            g_post_tensors_template[k].channel_stride = (int32_t)(h * w);
            g_post_tensors_template[k].row_stride = (int32_t)w;
            g_post_tensors_template[k].col_stride = 1;
        } else if (attr->fmt == RKNN_TENSOR_NHWC) {
            if (attr->n_dims != 4) {
                fprintf(stderr, "error: tensor %s NHWC n_dims=%u != 4\n", attr->name, attr->n_dims);
                return -1;
            }
            uint32_t w = attr->dims[2], c = attr->dims[3];
            g_post_tensors_template[k].n_channels = (int32_t)attr->dims[3];
            g_post_tensors_template[k].row_stride = (int32_t)(w * c);
            g_post_tensors_template[k].col_stride = (int32_t)c;
            g_post_tensors_template[k].channel_stride = 1;
        } else {
            fprintf(stderr, "error: unsupported tensor format %d for %s (want NCHW or NHWC)\n",
                    attr->fmt, attr->name);
            return -1;
        }
    }

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
    int eos = mpp_frame_get_eos(frame) ? 1 : 0;
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
        if ((int64_t)now > deadline + period) g_late++;
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

    /* Feed latest frame mailbox for NPU thread before deinit */
    if (!g_opt.no_npu) {
        pthread_mutex_lock(&g_mailbox.mutex);
        if (g_mailbox.has_frame) {
            if (g_mailbox.item.buf) {
                mpp_buffer_put(g_mailbox.item.buf);
            }
            g_mailbox.dropped_frames++;
        }
        mpp_buffer_inc_ref(buf);
        g_mailbox.item.buf = buf;
        g_mailbox.item.frame_id = g_frames;
        g_mailbox.item.hor_stride = mpp_frame_get_hor_stride(frame);
        g_mailbox.item.ver_stride = mpp_frame_get_ver_stride(frame);
        g_mailbox.item.width = mpp_frame_get_width(frame);
        g_mailbox.item.height = mpp_frame_get_height(frame);
        g_mailbox.item.fd = mpp_buffer_get_fd(buf);
        g_mailbox.has_frame = 1;
        pthread_cond_signal(&g_mailbox.cond);
        pthread_mutex_unlock(&g_mailbox.mutex);
    }

    mpp_frame_deinit(&frame);
    g_frames++;
    if (eos) { printf("decoder EOS (with last frame)\n"); return 1; }
    return (g_opt.frames > 0 && (long long)g_frames >= g_opt.frames) ? 1 : 0;
}

/* NPU worker thread: RGA pre-processing (crop + resize + NV12->RGB888) */
static void *npu_thread_func(void *arg)
{
    (void)arg;
    rga_buffer_t dst = wrapbuffer_handle(g_npu_dst_handle, 960, 320, RK_FORMAT_RGB_888, 960, 320);
    im_rect drect = { 0, 0, 960, 320 };
    im_rect srect = { 0, 360, 1920, 640 };
    rga_buffer_t pat = { 0 };
    im_rect prect = { 0 };
    int first_frame = 1;

    while (!g_stop) {
        FrameMailboxItem item;
        pthread_mutex_lock(&g_mailbox.mutex);
        while (!g_mailbox.has_frame && !g_mailbox.stop && !g_stop) {
            pthread_cond_wait(&g_mailbox.cond, &g_mailbox.mutex);
        }
        if ((g_mailbox.stop || g_stop) && !g_mailbox.has_frame) {
            pthread_mutex_unlock(&g_mailbox.mutex);
            break;
        }
        item = g_mailbox.item;
        g_mailbox.has_frame = 0;
        memset(&g_mailbox.item, 0, sizeof(g_mailbox.item));
        pthread_mutex_unlock(&g_mailbox.mutex);

        if (!item.buf) continue;

        uint64_t t0 = now_ns();

        /* Import source buffer */
        im_handle_param_t src_param;
        memset(&src_param, 0, sizeof(src_param));
        src_param.width = item.hor_stride;
        src_param.height = item.ver_stride;
        src_param.format = RK_FORMAT_YCbCr_420_SP;
        rga_buffer_handle_t src_handle = importbuffer_fd(item.fd, &src_param);
        if (src_handle <= 0) {
            fprintf(stderr, "importbuffer_fd failed for src frame %llu (fd=%d)\n",
                    (unsigned long long)item.frame_id, item.fd);
            mpp_buffer_put(item.buf);
            continue;
        }

        rga_buffer_t src = wrapbuffer_handle(src_handle, item.width, item.height,
                                             RK_FORMAT_YCbCr_420_SP, item.hor_stride, item.ver_stride);
        /* Explicitly specify BT.601 limited range on both src and dst */
        src.color_space_mode = IM_YUV_TO_RGB_BT601_LIMIT;
        dst.color_space_mode = IM_YUV_TO_RGB_BT601_LIMIT;

        if (first_frame) {
            IM_STATUS chk = imcheck(src, dst, srect, drect);
            if (chk != IM_STATUS_NOERROR && chk != IM_STATUS_SUCCESS) {
                fprintf(stderr, "RGA imcheck warning: %s (code %d)\n", imStrError(chk), (int)chk);
            } else {
                printf("RGA imcheck passed: crop (0,360,1920,640) NV12 -> (0,0,960,320) RGB888\n");
            }
            first_frame = 0;
        }

        IM_STATUS status = improcess(src, dst, pat, srect, drect, prect, 0);
        releasebuffer_handle(src_handle);

        if (status != IM_STATUS_SUCCESS && status != IM_STATUS_NOERROR) {
            fprintf(stderr, "RGA improcess error: %s (code %d) on frame %llu\n",
                    imStrError(status), (int)status, (unsigned long long)item.frame_id);
        } else {
            uint64_t t1 = now_ns();
            uint64_t dt = t1 - t0;
            g_rga_sum_ns += dt;
            if (dt > g_rga_max_ns) g_rga_max_ns = dt;
            g_npu_frames++;

            /* Dump RGB if requested */
            if (g_opt.dump_rgb && !g_dump_done && item.frame_id == g_opt.dump_at) {
                FILE *fp = fopen(g_opt.dump_rgb, "wb");
                if (fp) {
                    size_t nw = fwrite(g_npu_va, 1, 960 * 320 * 3, fp);
                    fclose(fp);
                    printf("dumped frame %llu RGB to %s (%zu bytes)\n",
                           (unsigned long long)item.frame_id, g_opt.dump_rgb, nw);
                } else {
                    fprintf(stderr, "failed to open %s: %s\n", g_opt.dump_rgb, strerror(errno));
                }
                g_dump_done = 1;
            }

            /* 2. RKNN Inference */
            if (!g_npu_zero_copy_in) {
                rknn_input in_obj;
                memset(&in_obj, 0, sizeof(in_obj));
                in_obj.index = 0;
                in_obj.type = RKNN_TENSOR_UINT8;
                in_obj.fmt = RKNN_TENSOR_NHWC;
                in_obj.size = (uint32_t)(960u * 320u * 3u);
                in_obj.buf = g_npu_va;
                in_obj.pass_through = 0;
                rknn_inputs_set(g_rknn_ctx, 1, &in_obj);
            }

            uint64_t t_inf0 = now_ns();
            int run_ret = rknn_run(g_rknn_ctx, NULL);
            uint64_t t_inf1 = now_ns();
            uint64_t dt_inf = t_inf1 - t_inf0;
            g_infer_sum_ns += dt_inf;
            if (dt_inf > g_infer_max_ns) g_infer_max_ns = dt_inf;

            if (run_ret != RKNN_SUCC) {
                fprintf(stderr, "rknn_run failed: %d on frame %llu\n",
                        run_ret, (unsigned long long)item.frame_id);
            } else {
                rknn_output normal_outputs[9];
                uint64_t dt_get = 0;
                int get_ok = 1;

                if (!g_opt.out_zc) {
                    memset(normal_outputs, 0, sizeof(normal_outputs));
                    for (uint32_t i = 0; i < 9; i++) {
                        normal_outputs[i].want_float = 0;
                        normal_outputs[i].is_prealloc = 0;
                        normal_outputs[i].index = i;
                    }
                    uint64_t t_get0 = now_ns();
                    int get_ret = rknn_outputs_get(g_rknn_ctx, 9, normal_outputs, NULL);
                    uint64_t t_get1 = now_ns();
                    dt_get = t_get1 - t_get0;
                    g_get_sum_ns += dt_get;
                    if (dt_get > g_get_max_ns) g_get_max_ns = dt_get;

                    if (get_ret != RKNN_SUCC) {
                        fprintf(stderr, "rknn_outputs_get failed: %d on frame %llu\n",
                                get_ret, (unsigned long long)item.frame_id);
                        get_ok = 0;
                    }
                }

                if (get_ok) {
                    /* 3. npu_post INT8 Post-Processing */
                    uint64_t t_post0 = now_ns();
                    npu_tensor_t post_tensors[9];
                    for (int k = 0; k < 9; k++) {
                        int out_idx = g_out_idx_map[k];
                        post_tensors[k] = g_post_tensors_template[k];
                        post_tensors[k].data = g_opt.out_zc ? g_zc_output_mems[out_idx]->virt_addr : normal_outputs[out_idx].buf;
                        post_tensors[k].scale = g_output_attrs[out_idx].scale;
                        post_tensors[k].zp = g_output_attrs[out_idx].zp;
                    }

                    npu_det_t band_dets[300];
                    npu_det_t src_dets[300];
                    int num_dets = npu_post_process_9tensors_int8(&g_npu_cfg, post_tensors, band_dets, 300);
                    npu_map_dets_to_src(band_dets, src_dets, num_dets);
                    uint64_t t_post1 = now_ns();
                    uint64_t dt_post = t_post1 - t_post0;
                    g_post_sum_ns += dt_post;
                    if (dt_post > g_post_max_ns) g_post_max_ns = dt_post;

                    /* In default mode: release outputs immediately after post-processing */
                    if (!g_opt.out_zc) {
                        rknn_outputs_release(g_rknn_ctx, 9, normal_outputs);
                    }

                    g_frame_total_sum_ns += (dt + dt_inf + dt_get + dt_post);
                    g_last_num_dets = num_dets;

                    /* 4. Pack up to 16 boxes and write BAR1 0x900-0x97F in a tight loop */
                    uint32_t box_regs[32];
                    npu_pack_box_regs(src_dets, num_dets, box_regs);
                    for (int b = 0; b < 32; b++) {
                        wr(0x900 + (uint32_t)(b * 4), box_regs[b]);
                    }

                    /* 5. Append detection to CSV if enabled */
                    if (g_csv_fp) {
                        uint64_t t_ms = now_ns() / 1000000ULL;
                        if (num_dets > 0) {
                            for (int d = 0; d < num_dets; d++) {
                                fprintf(g_csv_fp, "%llu,%llu,%d,%.4f,%.1f,%.1f,%.1f,%.1f\n",
                                        (unsigned long long)item.frame_id,
                                        (unsigned long long)t_ms,
                                        src_dets[d].cls,
                                        src_dets[d].score,
                                        src_dets[d].x0, src_dets[d].y0,
                                        src_dets[d].x1, src_dets[d].y1);
                            }
                        } else {
                            fprintf(g_csv_fp, "%llu,%llu,-1,0,0,0,0,0\n",
                                    (unsigned long long)item.frame_id,
                                    (unsigned long long)t_ms);
                        }
                    }
                }
            }
        }

        /* Release buffer reference back to MPP */
        mpp_buffer_put(item.buf);
    }

    return NULL;
}

static void print_stat(void)
{
    uint64_t now = now_ns(), dt = now - g_last_print_ns, df = g_frames - g_last_frames;
    double fps = dt ? (double)df * 1e9 / (double)dt : 0.0;
    double avg = g_frames ? (double)g_dma_sum_ns / (double)g_frames / 1e6 : 0.0;
    double rga_avg = g_npu_frames ? (double)g_rga_sum_ns / (double)g_npu_frames / 1e6 : 0.0;
    double infer_avg = g_npu_frames ? (double)g_infer_sum_ns / (double)g_npu_frames / 1e6 : 0.0;
    double get_avg = (!g_opt.out_zc && g_npu_frames) ? (double)g_get_sum_ns / (double)g_npu_frames / 1e6 : 0.0;
    double post_avg = g_npu_frames ? (double)g_post_sum_ns / (double)g_npu_frames / 1e6 : 0.0;
    double frame_total_avg = g_npu_frames ? (double)g_frame_total_sum_ns / (double)g_npu_frames / 1e6 : 0.0;

    uint64_t npu_df = g_npu_frames - g_last_npu_frames;
    double npu_fps = dt ? (double)npu_df * 1e9 / (double)dt : 0.0;
    uint64_t dropped;

    pthread_mutex_lock(&g_mailbox.mutex);
    dropped = g_mailbox.dropped_frames;
    pthread_mutex_unlock(&g_mailbox.mutex);

    /* Update text RAM line (row 2: 0xC80..0xCBF) if NPU enabled */
    if (!g_opt.no_npu && g_reg_map != MAP_FAILED) {
        char npu_line[64];
        npu_format_npu_line(npu_line, (int)(npu_fps + 0.5), (int)(frame_total_avg + 0.5), g_last_num_dets);
        uint32_t *dw = (uint32_t *)npu_line;
        for (int i = 0; i < 16; i++) {
            wr(0xC80 + (uint32_t)(i * 4), dw[i]);
        }
    }

    if (g_csv_fp) fflush(g_csv_fp);

    printf("[%6llus] frames=%llu fps=%.1f npu_frames=%llu npu_fps=%.1f npu_skip=%llu "
           "rga_avg=%.2fms infer_avg=%.2fms get_avg=%.2fms post_avg=%.2fms boxes=%d "
           "dma_avg=%.2fms dma_max=%.2fms late=%llu err=%llu newfr=%u uf=%u wait=%.0fms\n",
           (unsigned long long)(now / 1000000000ULL), (unsigned long long)g_frames, fps,
           (unsigned long long)g_npu_frames, npu_fps, (unsigned long long)dropped,
           rga_avg, infer_avg, get_avg, post_avg, g_last_num_dets,
           avg, (double)g_dma_max_ns / 1e6, (unsigned long long)g_late, (unsigned long long)g_err,
           rd(R_DISP_NEWFR) - g_newfr0, rd(R_DISP_UF) - g_uf0, (double)g_wait_ns / 1e6);
    g_last_print_ns = now;
    g_last_frames = g_frames;
    g_last_npu_frames = g_npu_frames;
}

static void print_summary(void)
{
    double avg = g_frames ? (double)g_dma_sum_ns / (double)g_frames / 1e6 : 0.0;
    double rga_avg = g_npu_frames ? (double)g_rga_sum_ns / (double)g_npu_frames / 1e6 : 0.0;
    double infer_avg = g_npu_frames ? (double)g_infer_sum_ns / (double)g_npu_frames / 1e6 : 0.0;
    double get_avg = (!g_opt.out_zc && g_npu_frames) ? (double)g_get_sum_ns / (double)g_npu_frames / 1e6 : 0.0;
    double post_avg = g_npu_frames ? (double)g_post_sum_ns / (double)g_npu_frames / 1e6 : 0.0;
    double frame_total_avg = g_npu_frames ? (double)g_frame_total_sum_ns / (double)g_npu_frames / 1e6 : 0.0;
    uint64_t dropped;

    pthread_mutex_lock(&g_mailbox.mutex);
    dropped = g_mailbox.dropped_frames;
    pthread_mutex_unlock(&g_mailbox.mutex);

    printf("---- summary ----\n");
    if (g_have_info)
        printf("info: %ux%u hor_stride=%u ver_stride=%u buf_size=%zu\n",
               g_info.w, g_info.h, g_info.hs, g_info.vs, g_info.buf_size);
    printf("frames=%llu avg_fps=%.1f npu_frames=%llu npu_skip=%llu avg_rga=%.2fms max_rga=%.2fms "
           "avg_infer=%.2fms max_infer=%.2fms avg_get=%.2fms max_get=%.2fms "
           "avg_post=%.2fms max_post=%.2fms avg_total=%.2fms "
           "avg_dma=%.2fms max_dma=%.2fms late=%llu err=%llu newfr=%u uf=%u wait=%.0fms\n",
           (unsigned long long)g_frames,
           (g_frames > 1) ? (double)(g_frames - 1) * 1e9 / (double)(now_ns() - g_t_first) : 0.0,
           (unsigned long long)g_npu_frames, (unsigned long long)dropped,
           rga_avg, (double)g_rga_max_ns / 1e6,
           infer_avg, (double)g_infer_max_ns / 1e6,
           get_avg, (double)g_get_max_ns / 1e6,
           post_avg, (double)g_post_max_ns / 1e6,
           frame_total_avg,
           avg, (double)g_dma_max_ns / 1e6,
           (unsigned long long)g_late, (unsigned long long)g_err,
           rd(R_DISP_NEWFR) - g_newfr0, rd(R_DISP_UF) - g_uf0, (double)g_wait_ns / 1e6);
}

static void cleanup(void)
{
    int i;

    /* 1. Stop NPU thread and drain mailbox */
    if (g_npu_thread_started) {
        pthread_mutex_lock(&g_mailbox.mutex);
        g_mailbox.stop = 1;
        pthread_cond_broadcast(&g_mailbox.cond);
        pthread_mutex_unlock(&g_mailbox.mutex);
        pthread_join(g_npu_tid, NULL);
        g_npu_thread_started = 0;
    }

    pthread_mutex_lock(&g_mailbox.mutex);
    if (g_mailbox.has_frame && g_mailbox.item.buf) {
        mpp_buffer_put(g_mailbox.item.buf);
        g_mailbox.item.buf = NULL;
        g_mailbox.has_frame = 0;
    }
    pthread_mutex_unlock(&g_mailbox.mutex);
    pthread_mutex_destroy(&g_mailbox.mutex);
    pthread_cond_destroy(&g_mailbox.cond);

    /* 2. Reset box registers and text RAM, close CSV, destroy RKNN */
    if (!g_opt.no_npu) {
        if (g_reg_map != MAP_FAILED) {
            for (i = 0; i < 32; i++) wr(0x900 + (uint32_t)(i * 4), 0);
            char spaces[64];
            memset(spaces, ' ', 64);
            uint32_t *sp_dw = (uint32_t *)spaces;
            for (i = 0; i < 16; i++) wr(0xC80 + (uint32_t)(i * 4), sp_dw[i]);
        }
        if (g_rknn_ctx) {
            if (g_zc_input_mem) {
                rknn_destroy_mem(g_rknn_ctx, g_zc_input_mem);
                g_zc_input_mem = NULL;
            }
            if (g_opt.out_zc) {
                for (i = 0; i < 9; i++) {
                    if (g_zc_output_mems[i]) {
                        rknn_destroy_mem(g_rknn_ctx, g_zc_output_mems[i]);
                        g_zc_output_mems[i] = NULL;
                    }
                }
            }
            rknn_destroy(g_rknn_ctx);
            g_rknn_ctx = 0;
        }
        if (g_csv_fp) {
            fflush(g_csv_fp);
            fclose(g_csv_fp);
            g_csv_fp = NULL;
        }
    }

    /* 3. Release RGA and CMA buffers */
    if (g_npu_dst_handle > 0) {
        releasebuffer_handle(g_npu_dst_handle);
        g_npu_dst_handle = 0;
    }
    if (g_npu_va != MAP_FAILED && g_npu_va != NULL) {
        munmap(g_npu_va, g_npu_buf_len);
        g_npu_va = MAP_FAILED;
    }
    if (g_npu_fd >= 0) {
        close(g_npu_fd);
        g_npu_fd = -1;
    }

    /* 4. MPP & BAR1 cleanup */
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
    uint64_t t_quiet = 0;

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
            if (g_frames == 0) return 3;
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
        "  --codec hevc|h264       --fps N(0=unlimited)  --ext-bufs N (alias --bufs, def: 26)\n"
        "  --chunk BYTES(<=4MB)    --frames N(0=all)     --loop\n"
        "  --heap NAME             --ext-type ext_dma|drm|dma_heap  --ctrl HEX\n"
        "  --no-npu                (disable NPU thread; behaves as pure feeder)\n"
        "  --out-zc                (zero-copy outputs via rknn_create_mem; def, same as no option)\n"
        "  --out-get               (use rknn_outputs_get instead of zero-copy outputs)\n"
        "  --dump-rgb <path>       (dump RGA RGB888 output to file)\n"
        "  --dump-at <frame_id>    (frame index to dump, default: 0)\n"
        "  --model <path>          (path to .rknn model, parsed for stage 2)\n"
        "  --conf <float>          (detection confidence threshold, def: 0.25)\n"
        "  --iou <float>           (NMS IoU threshold, def: 0.60)\n"
        "  --nms agnostic|class|pr_split (NMS mode, def: pr_split)\n"
        "  --csv <path>            (path to detection CSV output)\n", p);
}

int main(int argc, char **argv)
{
    uint32_t bar1;
    int i, rc;
    struct sigaction sa;
    struct stat st;

    memset(&g_opt, 0, sizeof(g_opt));
    for (i = 0; i < 64; i++) g_fd[i] = -1;
    g_opt.codec = "hevc"; g_opt.fps = 30;
    /* 26 external buffers: 24 base + 2 margin for mailbox + NPU thread */
    g_opt.bufs = 26;
    g_opt.chunk = 262144; g_opt.frames = 0; g_opt.heap = "cma";
    g_opt.ext_type = EXT_DMA; g_opt.ext_mpp = MPP_BUFFER_TYPE_EXT_DMA;
    g_opt.conf = 0.25f; g_opt.iou = 0.60f; g_opt.nms = "pr_split";
    g_opt.out_zc = 1;  /* 默认零拷贝输出（板上已与 rknn_outputs_get 逐框一致且更快） */

    if (argc < 3) { usage(argv[0]); return 2; }
    for (i = 3; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--codec") && i + 1 < argc) g_opt.codec = argv[++i];
        else if (!strcmp(a, "--fps") && i + 1 < argc) g_opt.fps = (int)strtoll(argv[++i], NULL, 0);
        else if ((!strcmp(a, "--bufs") || !strcmp(a, "--ext-bufs")) && i + 1 < argc)
            g_opt.bufs = (int)strtoll(argv[++i], NULL, 0);
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
        else if (!strcmp(a, "--no-npu")) g_opt.no_npu = 1;
        else if (!strcmp(a, "--out-zc")) g_opt.out_zc = 1;
        else if (!strcmp(a, "--out-get")) g_opt.out_zc = 0;
        else if (!strcmp(a, "--dump-rgb") && i + 1 < argc) g_opt.dump_rgb = argv[++i];
        else if (!strcmp(a, "--dump-at") && i + 1 < argc) {
            g_opt.dump_at = (uint64_t)strtoull(argv[++i], NULL, 0);
            g_opt.have_dump_at = 1;
        }
        else if (!strcmp(a, "--model") && i + 1 < argc) g_opt.model = argv[++i];
        else if (!strcmp(a, "--conf") && i + 1 < argc) g_opt.conf = (float)atof(argv[++i]);
        else if (!strcmp(a, "--iou") && i + 1 < argc) g_opt.iou = (float)atof(argv[++i]);
        else if (!strcmp(a, "--nms") && i + 1 < argc) g_opt.nms = argv[++i];
        else if (!strcmp(a, "--csv") && i + 1 < argc) g_opt.csv = argv[++i];
        else { fprintf(stderr, "unknown option: %s\n", a); usage(argv[0]); return 2; }
    }

    if (!strcmp(g_opt.codec, "hevc")) g_opt.ctx_codec = MPP_VIDEO_CodingHEVC;
    else if (!strcmp(g_opt.codec, "h264")) g_opt.ctx_codec = MPP_VIDEO_CodingAVC;
    else { fprintf(stderr, "bad --codec %s\n", g_opt.codec); return 2; }
    if (g_opt.ext_type == EXT_DRM) g_opt.ext_mpp = MPP_BUFFER_TYPE_DRM;
    else if (g_opt.ext_type == EXT_DMAHEAP) g_opt.ext_mpp = MPP_BUFFER_TYPE_DMA_HEAP;
    if (g_opt.bufs < 1 || g_opt.bufs > 64) { fprintf(stderr, "--ext-bufs/--bufs must be 1..64\n"); return 2; }
    if (g_opt.chunk == 0 || (g_opt.chunk & 255u) != 0 || g_opt.chunk > (4u << 20)) {
        fprintf(stderr, "--chunk must be a 256-multiple <= 4MB\n"); return 2;
    }
    if (g_opt.fps < 0) { fprintf(stderr, "--fps must be >= 0\n"); return 2; }

    /* Initialize latest frame mailbox */
    pthread_mutex_init(&g_mailbox.mutex, NULL);
    pthread_cond_init(&g_mailbox.cond, NULL);
    g_mailbox.has_frame = 0;
    g_mailbox.stop = 0;
    g_mailbox.dropped_frames = 0;

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

    /* Start NPU thread & CMA RGB buffer & RKNN unless --no-npu */
    if (!g_opt.no_npu) {
        if (!g_opt.model) {
            fprintf(stderr, "error: --model <path> is required when NPU is enabled (or specify --no-npu)\n");
            g_exit_code = 2;
            goto out;
        }
        if (g_opt.csv) {
            g_csv_fp = fopen(g_opt.csv, "w");
            if (!g_csv_fp) {
                fprintf(stderr, "error: failed to open CSV '%s': %s\n", g_opt.csv, strerror(errno));
                g_exit_code = 1;
                goto out;
            }
            fprintf(g_csv_fp, "frame,time_ms,cls,score,x0,y0,x1,y1\n");
        }
        npu_post_config_init(&g_npu_cfg);
        g_npu_cfg.conf_thres = g_opt.conf;
        g_npu_cfg.iou_thres = g_opt.iou;
        g_npu_cfg.max_cand = 1000;
        g_npu_cfg.max_det = 300;
        if (!strcmp(g_opt.nms, "agnostic")) g_npu_cfg.mode = NPU_NMS_AGNOSTIC;
        else if (!strcmp(g_opt.nms, "class")) g_npu_cfg.mode = NPU_NMS_CLASS;
        else if (!strcmp(g_opt.nms, "pr_split")) g_npu_cfg.mode = NPU_NMS_PR_SPLIT;
        else {
            fprintf(stderr, "bad --nms %s (want agnostic|class|pr_split)\n", g_opt.nms);
            g_exit_code = 2;
            goto out;
        }

        if (alloc_npu_buffer() < 0) {
            fprintf(stderr, "alloc_npu_buffer failed\n");
            g_exit_code = 1;
            goto out;
        }
        if (init_rknn() < 0) {
            fprintf(stderr, "init_rknn failed\n");
            g_exit_code = 1;
            goto out;
        }
        if (pthread_create(&g_npu_tid, NULL, npu_thread_func, NULL) != 0) {
            perror("pthread_create (NPU thread)");
            g_exit_code = 1;
            goto out;
        }
        g_npu_thread_started = 1;
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
    /* OSD_CTRL: bit4=检测框、bit5=文字；复位值 0x60 只含文字/箭头，不含检测框位
       （见 FPGA rt_ext_regs.v:151），故此处置位 0x30。 */
    if (!g_opt.no_npu) wr(R_OSD_CTRL, rd(R_OSD_CTRL) | 0x30u);
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

    /* Stop NPU thread before summary so final stats are consistent */
    if (g_npu_thread_started) {
        pthread_mutex_lock(&g_mailbox.mutex);
        g_mailbox.stop = 1;
        pthread_cond_broadcast(&g_mailbox.cond);
        pthread_mutex_unlock(&g_mailbox.mutex);
        pthread_join(g_npu_tid, NULL);
        g_npu_thread_started = 0;
    }

    print_summary();

out:
    cleanup();
    return g_exit_code;
}
