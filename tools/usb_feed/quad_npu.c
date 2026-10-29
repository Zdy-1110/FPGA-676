#define _GNU_SOURCE
#include "quad_npu.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <pthread.h>

#include "rknn_api.h"
#include "rga.h"
#include "im2d.h"
#include "npu_post.h"
#include "quad_sched.h"

struct dma_heap_allocation_data {
    uint64_t len;
    uint32_t fd;
    uint32_t fd_flags;
    uint64_t heap_flags;
};
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)

static const char *k_canonical_output_names[9] = {
    "box_s8", "cls_s8", "sum_s8",
    "box_s16", "cls_s16", "sum_s16",
    "box_s32", "cls_s32", "sum_s32"
};

typedef struct {
    int fd;
    void *va;
    size_t len;
    rga_buffer_handle_t rga_handle;
    rknn_tensor_mem *zc_mem;
} qnpu_buf_t;

enum {
    REQ_IDLE = 0,
    REQ_NOMINATED,
    REQ_FILLING,
    REQ_READY,
    REQ_CANCELLED
};

typedef struct {
    int state;
    int ch;
    int buf_idx;
    uint64_t req_seq;
    uint64_t frame_id;
    uint64_t timestamp_ns;
} qnpu_slot_t;

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    qnpu_slot_t slots[2];
    uint64_t next_seq;
} qnpu_nom_mgr_t;

static QnpuCfg g_cfg;
static volatile uint32_t *g_bar1 = NULL;
static rknn_context g_ctx = 0;
static rknn_input_output_num g_io_num;
static rknn_tensor_attr g_input_attrs[1];
static rknn_tensor_attr g_output_attrs[9];
static rknn_tensor_mem *g_zc_output_mems[9];
static int g_out_idx_map[9];
static npu_tensor_t g_post_tensors_template[9];
static npu_post_config_t g_post_cfg;

static qnpu_buf_t g_bufs[3];
static qnpu_nom_mgr_t g_nom;
static int g_slot_order[2];
static int g_slot_order_count = 0;
static volatile int g_ch_nominated[4];

static pthread_mutex_t g_reg_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_valid_mask = 0;
static quad_rect_t g_band_rects[4];
static int g_src_w[4], g_src_h[4];
static bool g_ch_registered[4];

static quad_swrr_t g_swrr;
static quad_osd_cache_t g_osd_cache;
static uint64_t g_ch_last_det_ns[4];
static bool g_ch_has_boxes[4];

static pthread_mutex_t g_box_mutex = PTHREAD_MUTEX_INITIALIZER;
static npu_det_t g_last_boxes[4][4];
static int g_last_box_count[4];

static pthread_mutex_t g_stats_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_ch_frames[4];
static uint64_t g_ch_last_sec_frames[4];
static double g_ch_fps[4];
static uint64_t g_total_frames;
static uint64_t g_total_last_sec_frames;
static double g_total_fps;
static uint64_t g_last_text_ns;

static uint64_t g_run_sum_ns;
static uint64_t g_run_count;
static uint64_t g_bind_sum_ns;
static uint64_t g_bind_count;
static uint64_t g_wait_sum_ns;
static uint64_t g_wait_count;
static int g_timeouts[4];

static int g_dump_count[4];
static pthread_t g_worker_thread;
static volatile int g_stop = 0;
static volatile int g_inited = 0;

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
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

static int alloc_dma_buf(qnpu_buf_t *buf, size_t size)
{
    char path[128];
    int hfd;
    struct dma_heap_allocation_data data;
    im_handle_param_t dst_param;

    snprintf(path, sizeof(path), "/dev/dma_heap/cma");
    hfd = open(path, O_RDWR | O_CLOEXEC);
    if (hfd < 0) {
        snprintf(path, sizeof(path), "/dev/dma_heap/system");
        hfd = open(path, O_RDWR | O_CLOEXEC);
        if (hfd < 0) {
            perror("open /dev/dma_heap/cma and system");
            return -1;
        }
    }

    buf->len = (size + 4095u) & ~(size_t)4095u;
    memset(&data, 0, sizeof(data));
    data.len = buf->len;
    data.fd_flags = O_RDWR | O_CLOEXEC;
    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) {
        perror("DMA_HEAP_IOCTL_ALLOC");
        close(hfd);
        return -1;
    }
    close(hfd);
    buf->fd = data.fd;

    buf->va = mmap(NULL, buf->len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, buf->fd, 0);
    if (buf->va == MAP_FAILED) {
        perror("mmap dma buf");
        close(buf->fd);
        buf->fd = -1;
        return -1;
    }

    memset(&dst_param, 0, sizeof(dst_param));
    dst_param.width = 960;
    dst_param.height = 320;
    dst_param.format = RK_FORMAT_RGB_888;
    buf->rga_handle = importbuffer_fd(buf->fd, &dst_param);
    if (buf->rga_handle <= 0) {
        fprintf(stderr, "importbuffer_fd failed for dma buf\n");
        munmap(buf->va, buf->len);
        close(buf->fd);
        buf->fd = -1;
        return -1;
    }

    buf->zc_mem = rknn_create_mem_from_fd(g_ctx, buf->fd, buf->va, (uint32_t)buf->len, 0);
    if (!buf->zc_mem) {
        fprintf(stderr, "rknn_create_mem_from_fd failed for dma buf\n");
        releasebuffer_handle(buf->rga_handle);
        munmap(buf->va, buf->len);
        close(buf->fd);
        buf->fd = -1;
        return -1;
    }

    return 0;
}

static void qnpu_rga_crop(int ch, const QnpuSrc *src, int target_buf)
{
    rga_buffer_t dst = wrapbuffer_handle(g_bufs[target_buf].rga_handle, 960, 320, RK_FORMAT_RGB_888, 960, 320);
    im_rect drect = { 0, 0, 960, 320 };
    quad_rect_t br;
    pthread_mutex_lock(&g_reg_mutex);
    br = g_band_rects[ch];
    pthread_mutex_unlock(&g_reg_mutex);
    im_rect srect = { br.x, br.y, br.w, br.h };
    rga_buffer_t pat = { 0 };
    im_rect prect = { 0 };

    rga_buffer_handle_t src_handle = 0;
    int need_release = 0;
    int fmt = src->format ? src->format : RK_FORMAT_YCbCr_420_SP;
    if (src->handle > 0) {
        src_handle = (rga_buffer_handle_t)src->handle;
    } else {
        im_handle_param_t src_param;
        memset(&src_param, 0, sizeof(src_param));
        src_param.width = src->wstride;
        src_param.height = src->hstride;
        src_param.format = fmt;
        src_handle = importbuffer_fd(src->fd, &src_param);
        need_release = 1;
    }
    if (src_handle <= 0) {
        return;
    }

    rga_buffer_t rga_src = wrapbuffer_handle(src_handle, src->width, src->height, fmt, src->wstride, src->hstride);
    rga_src.color_space_mode = IM_YUV_TO_RGB_BT601_LIMIT;
    dst.color_space_mode = IM_YUV_TO_RGB_BT601_LIMIT;

    improcess(rga_src, dst, pat, srect, drect, prect, 0);

    if (need_release && src_handle > 0) {
        releasebuffer_handle(src_handle);
    }
}

static void qnpu_maybe_dump(int ch, const void *rgb_va, const npu_det_t *dets, int num_dets)
{
    if (g_cfg.dump_n <= 0 || ch < 0 || ch >= 4) return;
    if (g_dump_count[ch] >= g_cfg.dump_n) return;

    const char *dir = g_cfg.dump_dir ? g_cfg.dump_dir : "/tmp/qnpu_dump";
    mkdir(dir, 0755);

    char path_rgb[256];
    snprintf(path_rgb, sizeof(path_rgb), "%s/ch%d_%03d.rgb", dir, ch, g_dump_count[ch]);
    FILE *fp = fopen(path_rgb, "wb");
    if (fp) {
        fwrite(rgb_va, 1, 960 * 320 * 3, fp);
        fclose(fp);
    }

    char path_txt[256];
    snprintf(path_txt, sizeof(path_txt), "%s/ch%d_%03d.txt", dir, ch, g_dump_count[ch]);
    fp = fopen(path_txt, "w");
    if (fp) {
        for (int i = 0; i < num_dets; i++) {
            fprintf(fp, "%d %.4f %.1f %.1f %.1f %.1f\n",
                    dets[i].cls, dets[i].score,
                    dets[i].x0, dets[i].y0, dets[i].x1, dets[i].y1);
        }
        fclose(fp);
    }
    g_dump_count[ch]++;
}

static void qnpu_update_text_ram(uint64_t now_ns_val)
{
    if (!g_bar1) return;

    double dt_sec = (double)(now_ns_val - g_last_text_ns) / 1e9;
    if (dt_sec <= 0.0) return;

    pthread_mutex_lock(&g_stats_mutex);
    uint64_t df_tot = g_total_frames - g_total_last_sec_frames;
    g_total_fps = (double)df_tot / dt_sec;
    g_total_last_sec_frames = g_total_frames;

    for (int i = 0; i < 4; i++) {
        uint64_t df = g_ch_frames[i] - g_ch_last_sec_frames[i];
        g_ch_fps[i] = (double)df / dt_sec;
        g_ch_last_sec_frames[i] = g_ch_frames[i];
    }

    double run_avg = g_run_count ? ((double)g_run_sum_ns / (double)g_run_count / 1e6) : 0.0;
    int total_to = g_timeouts[0] + g_timeouts[1] + g_timeouts[2] + g_timeouts[3];

    char text[64];
    memset(text, ' ', 64);
    int len = snprintf(text, 64, "NPU %.1ffps %.1fms 0:%.0f 1:%.0f 2:%.0f 3:%.0f to:%d",
                       g_total_fps, run_avg,
                       g_ch_fps[0], g_ch_fps[1], g_ch_fps[2], g_ch_fps[3],
                       total_to);
    if (len > 0 && len < 64) {
        text[len] = ' ';
    }
    pthread_mutex_unlock(&g_stats_mutex);

    for (int i = 0; i < 16; i++) {
        uint32_t val = (uint8_t)text[i * 4 + 0] |
                       ((uint8_t)text[i * 4 + 1] << 8) |
                       ((uint8_t)text[i * 4 + 2] << 16) |
                       ((uint8_t)text[i * 4 + 3] << 24);
        g_bar1[(0xC80u + (uint32_t)(i * 4)) / 4] = val;
    }
}

static int try_nominate_slot(int cur_infer_buf)
{
    pthread_mutex_lock(&g_reg_mutex);
    uint32_t mask = g_valid_mask;
    int num_valid = 0;
    for (int i = 0; i < 4; i++) {
        if (mask & (1u << i)) num_valid++;
    }
    if (num_valid == 0) {
        pthread_mutex_unlock(&g_reg_mutex);
        return 0;
    }

    pthread_mutex_lock(&g_nom.mutex);
    if (g_slot_order_count >= 2) {
        pthread_mutex_unlock(&g_nom.mutex);
        pthread_mutex_unlock(&g_reg_mutex);
        return 0;
    }

    int idle_slot = -1;
    for (int i = 0; i < 2; i++) {
        if (g_nom.slots[i].state == REQ_IDLE) {
            idle_slot = i;
            break;
        }
    }
    if (idle_slot < 0) {
        pthread_mutex_unlock(&g_nom.mutex);
        pthread_mutex_unlock(&g_reg_mutex);
        return 0;
    }

    int other_slot = 1 - idle_slot;
    int busy_ch = (g_nom.slots[other_slot].state != REQ_IDLE) ? g_nom.slots[other_slot].ch : -1;
    int other_buf = (g_nom.slots[other_slot].state != REQ_IDLE) ? g_nom.slots[other_slot].buf_idx : -1;

    if (num_valid <= 1 && busy_ch >= 0) {
        pthread_mutex_unlock(&g_nom.mutex);
        pthread_mutex_unlock(&g_reg_mutex);
        return 0;
    }

    int target_ch = -1;
    for (int attempt = 0; attempt < 8; attempt++) {
        int ch = quad_swrr_next(&g_swrr);
        if (ch >= 0 && ch != busy_ch) {
            target_ch = ch;
            break;
        }
    }
    pthread_mutex_unlock(&g_reg_mutex);

    if (target_ch < 0) {
        pthread_mutex_unlock(&g_nom.mutex);
        return 0;
    }

    int target_buf = -1;
    for (int b = 0; b < 3; b++) {
        if (b != cur_infer_buf && b != other_buf) {
            target_buf = b;
            break;
        }
    }
    if (target_buf < 0) {
        pthread_mutex_unlock(&g_nom.mutex);
        return 0;
    }

    g_nom.next_seq++;
    qnpu_slot_t *slot = &g_nom.slots[idle_slot];
    slot->req_seq = g_nom.next_seq;
    slot->state = REQ_NOMINATED;
    slot->ch = target_ch;
    slot->buf_idx = target_buf;
    __atomic_store_n(&g_ch_nominated[target_ch], 1, __ATOMIC_RELEASE);
    g_slot_order[g_slot_order_count++] = idle_slot;

    pthread_mutex_unlock(&g_nom.mutex);
    return 1;
}

static int wait_earliest_slot(int *out_buf, int *out_ch)
{
    pthread_mutex_lock(&g_nom.mutex);
    if (g_slot_order_count == 0) {
        pthread_mutex_unlock(&g_nom.mutex);
        return -1;
    }

    int s = g_slot_order[0];
    qnpu_slot_t *slot = &g_nom.slots[s];
    uint64_t wait_seq = slot->req_seq;
    int target_ch = slot->ch;
    int target_buf = slot->buf_idx;

    uint64_t tw0 = now_ns();
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    ts.tv_nsec += 100 * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec += 1;
        ts.tv_nsec -= 1000000000L;
    }

    while ((slot->state == REQ_NOMINATED || slot->state == REQ_FILLING) &&
           slot->req_seq == wait_seq && !g_stop) {
        if (pthread_cond_timedwait(&g_nom.cond, &g_nom.mutex, &ts) != 0) break;
    }
    if (slot->state == REQ_FILLING && slot->req_seq == wait_seq && !g_stop) {
        struct timespec ts_extra;
        clock_gettime(CLOCK_MONOTONIC, &ts_extra);
        ts_extra.tv_nsec += 50 * 1000000L;
        if (ts_extra.tv_nsec >= 1000000000L) {
            ts_extra.tv_sec += 1;
            ts_extra.tv_nsec -= 1000000000L;
        }
        while (slot->state == REQ_FILLING && slot->req_seq == wait_seq && !g_stop) {
            if (pthread_cond_timedwait(&g_nom.cond, &g_nom.mutex, &ts_extra) != 0) break;
        }
    }

    int ok = 0;
    if (slot->state == REQ_READY && slot->req_seq == wait_seq) {
        ok = 1;
        slot->state = REQ_IDLE;
    } else {
        if (slot->state == REQ_NOMINATED && slot->req_seq == wait_seq) {
            slot->state = REQ_CANCELLED;
            __atomic_store_n(&g_ch_nominated[target_ch], 0, __ATOMIC_RELEASE);
        } else if (slot->state == REQ_FILLING && slot->req_seq == wait_seq) {
            fprintf(stderr, "warning: channel %d RGA fill timed out (>150ms)\n", target_ch);
            slot->state = REQ_CANCELLED;
        }
        pthread_mutex_lock(&g_stats_mutex);
        g_timeouts[target_ch]++;
        pthread_mutex_unlock(&g_stats_mutex);
    }

    if (g_slot_order_count == 2) {
        g_slot_order[0] = g_slot_order[1];
    }
    g_slot_order_count--;
    pthread_mutex_unlock(&g_nom.mutex);

    uint64_t tw1 = now_ns();
    pthread_mutex_lock(&g_stats_mutex);
    g_wait_sum_ns += (tw1 - tw0);
    g_wait_count++;
    pthread_mutex_unlock(&g_stats_mutex);

    if (ok) {
        if (out_buf) *out_buf = target_buf;
        if (out_ch) *out_ch = target_ch;
        return 0;
    }
    return -1;
}

static void *npu_worker_thread(void *arg)
{
    (void)arg;
    rknn_tensor_attr in_attr = g_input_attrs[0];
    in_attr.type = RKNN_TENSOR_UINT8;
    in_attr.fmt = RKNN_TENSOR_NHWC;
    in_attr.pass_through = 0;

    int cur_buf = -1;
    int cur_ch = -1;
    int cur_valid = 0;

    while (!g_stop) {
        /* 1. If cur_buf is not valid, block until we obtain a valid frame */
        while (!g_stop && !cur_valid) {
            while (g_slot_order_count < 2 && try_nominate_slot(-1)) ;

            if (g_slot_order_count == 0) {
                usleep(5000);
                continue;
            }

            int ready_buf = -1, ready_ch = -1;
            if (wait_earliest_slot(&ready_buf, &ready_ch) == 0) {
                cur_buf = ready_buf;
                cur_ch = ready_ch;
                cur_valid = 1;
            }
        }
        if (g_stop) break;

        /* 2. Top-up nominations to depth 2 while cur_buf is being inferred */
        while (g_slot_order_count < 2 && try_nominate_slot(cur_buf)) ;

        /* 3. Infer cur_buf and post-process */
        uint64_t tb0 = now_ns();
        int set_ret = rknn_set_io_mem(g_ctx, g_bufs[cur_buf].zc_mem, &in_attr);
        uint64_t tb1 = now_ns();
        uint64_t dt_bind = tb1 - tb0;

        uint64_t tr0 = now_ns();
        int run_ret = rknn_run(g_ctx, NULL);
        uint64_t tr1 = now_ns();
        uint64_t dt_run = tr1 - tr0;

        pthread_mutex_lock(&g_stats_mutex);
        g_bind_sum_ns += dt_bind;
        g_bind_count++;
        g_run_sum_ns += dt_run;
        g_run_count++;
        pthread_mutex_unlock(&g_stats_mutex);

        if (run_ret == RKNN_SUCC && set_ret == RKNN_SUCC) {
            npu_tensor_t post_tensors[9];
            for (int k = 0; k < 9; k++) {
                int out_idx = g_out_idx_map[k];
                post_tensors[k] = g_post_tensors_template[k];
                post_tensors[k].data = g_zc_output_mems[out_idx]->virt_addr;
                post_tensors[k].scale = g_output_attrs[out_idx].scale;
                post_tensors[k].zp = g_output_attrs[out_idx].zp;
            }

            npu_det_t band_dets[300];
            int num_dets = npu_post_process_9tensors_int8(&g_post_cfg, post_tensors, band_dets, 300);

            qnpu_maybe_dump(cur_ch, g_bufs[cur_buf].va, band_dets, num_dets);

            npu_det_t top4[4];
            int n4 = quad_select_top4(band_dets, num_dets, g_cfg.conf_thres, top4);

            npu_det_t screen_top4[4];
            for (int k = 0; k < n4; k++) {
                quad_band_to_screen_det(cur_ch, &top4[k], &screen_top4[k]);
            }

            pthread_mutex_lock(&g_box_mutex);
            g_last_box_count[cur_ch] = n4;
            for (int k = 0; k < n4; k++) {
                g_last_boxes[cur_ch][k] = screen_top4[k];
            }
            pthread_mutex_unlock(&g_box_mutex);

            uint32_t regs[8];
            quad_pack_ch_regs(screen_top4, n4, regs);

            quad_reg_write_t writes[16];
            int nw = quad_sched_diff_ch_regs(&g_osd_cache, cur_ch, regs, writes, 16);

            if (g_bar1 && nw > 0) {
                for (int w = 0; w < nw; w++) {
                    g_bar1[writes[w].offset / 4] = writes[w].val;
                }
            }

            pthread_mutex_lock(&g_stats_mutex);
            g_ch_frames[cur_ch]++;
            g_total_frames++;
            g_ch_last_det_ns[cur_ch] = now_ns();
            g_ch_has_boxes[cur_ch] = (n4 > 0);
            pthread_mutex_unlock(&g_stats_mutex);
        }

        /* 4. Wait for next frame from earliest nominated slot */
        int next_ready_buf = -1, next_ready_ch = -1;
        if (wait_earliest_slot(&next_ready_buf, &next_ready_ch) == 0) {
            cur_buf = next_ready_buf;
            cur_ch = next_ready_ch;
            cur_valid = 1;
            /* Immediately top up the freed slot with the next nomination */
            while (g_slot_order_count < 2 && try_nominate_slot(cur_buf)) ;
        } else {
            cur_valid = 0;
            cur_buf = -1;
            cur_ch = -1;
        }

        /* 5. Timeout clear (500 ms) and Text RAM update (1 s) */
        uint64_t now = now_ns();
        for (int ch = 0; ch < 4; ch++) {
            if (g_ch_has_boxes[ch] && (now - g_ch_last_det_ns[ch] > 500000000ULL)) {
                quad_reg_write_t clr[8];
                int cn = quad_sched_timeout_clear_ch(&g_osd_cache, ch, clr, 8);
                if (g_bar1 && cn > 0) {
                    for (int w = 0; w < cn; w++) {
                        g_bar1[clr[w].offset / 4] = clr[w].val;
                    }
                }
                g_ch_has_boxes[ch] = false;
                pthread_mutex_lock(&g_box_mutex);
                g_last_box_count[ch] = 0;
                pthread_mutex_unlock(&g_box_mutex);
            }
        }

        if (now - g_last_text_ns >= 1000000000ULL) {
            qnpu_update_text_ram(now);
            g_last_text_ns = now;
        }
    }

    return NULL;
}

int qnpu_init(const QnpuCfg *cfg, volatile uint32_t *bar1)
{
    if (!cfg || !cfg->model_path) return -1;
    g_cfg = *cfg;
    if (g_cfg.weights[0] == 0 && g_cfg.weights[1] == 0 &&
        g_cfg.weights[2] == 0 && g_cfg.weights[3] == 0) {
        g_cfg.weights[0] = 2;
        g_cfg.weights[1] = 1;
        g_cfg.weights[2] = 1;
        g_cfg.weights[3] = 1;
    }
    if (g_cfg.conf_thres <= 0.0f) {
        g_cfg.conf_thres = 0.25f;
    }
    if (!g_cfg.dump_dir) {
        g_cfg.dump_dir = "/tmp/qnpu_dump";
    }

    quad_swrr_init(&g_swrr, g_cfg.weights, 0);
    quad_osd_cache_init(&g_osd_cache);

    pthread_mutex_lock(&g_box_mutex);
    for (int i = 0; i < 4; i++) {
        g_last_box_count[i] = 0;
    }
    pthread_mutex_unlock(&g_box_mutex);

    if (bar1) {
        g_bar1 = bar1;
        uint32_t ctrl = g_bar1[0x880u / 4];
        g_bar1[0x880u / 4] = ctrl | 0x30u;
    }

    /* Load RKNN model */
    FILE *fp = fopen(g_cfg.model_path, "rb");
    if (!fp) {
        fprintf(stderr, "error: cannot open model '%s'\n", g_cfg.model_path);
        return -1;
    }
    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    void *model_data = malloc((size_t)sz);
    if (!model_data) {
        fclose(fp);
        return -1;
    }
    if (fread(model_data, 1, (size_t)sz, fp) != (size_t)sz) {
        free(model_data);
        fclose(fp);
        return -1;
    }
    fclose(fp);

    int ret = rknn_init(&g_ctx, model_data, (uint32_t)sz, 0, NULL);
    free(model_data);
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "error: rknn_init failed (%d)\n", ret);
        return -1;
    }

    memset(&g_io_num, 0, sizeof(g_io_num));
    ret = rknn_query(g_ctx, RKNN_QUERY_IN_OUT_NUM, &g_io_num, sizeof(g_io_num));
    if (ret != RKNN_SUCC || g_io_num.n_input != 1 || g_io_num.n_output != 9) {
        fprintf(stderr, "error: unexpected model I/O: %u in, %u out\n", g_io_num.n_input, g_io_num.n_output);
        return -1;
    }

    memset(g_input_attrs, 0, sizeof(g_input_attrs));
    g_input_attrs[0].index = 0;
    ret = rknn_query(g_ctx, RKNN_QUERY_INPUT_ATTR, &g_input_attrs[0], sizeof(rknn_tensor_attr));
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "error: rknn_query(INPUT_ATTR) failed (%d)\n", ret);
        return -1;
    }

    memset(g_output_attrs, 0, sizeof(g_output_attrs));
    for (uint32_t i = 0; i < 9; i++) {
        g_output_attrs[i].index = i;
        ret = rknn_query(g_ctx, RKNN_QUERY_OUTPUT_ATTR, &g_output_attrs[i], sizeof(rknn_tensor_attr));
        if (ret != RKNN_SUCC) {
            fprintf(stderr, "error: rknn_query(OUTPUT_ATTR) idx %u failed (%d)\n", i, ret);
            return -1;
        }
    }

    /* Zero-copy output buffers */
    for (uint32_t i = 0; i < 9; i++) {
        uint32_t mem_sz = g_output_attrs[i].size_with_stride > g_output_attrs[i].size ?
                          g_output_attrs[i].size_with_stride : g_output_attrs[i].size;
        g_zc_output_mems[i] = rknn_create_mem(g_ctx, mem_sz);
        if (!g_zc_output_mems[i]) {
            fprintf(stderr, "error: rknn_create_mem failed for out %u\n", i);
            return -1;
        }
        ret = rknn_set_io_mem(g_ctx, g_zc_output_mems[i], &g_output_attrs[i]);
        if (ret != RKNN_SUCC) {
            fprintf(stderr, "error: rknn_set_io_mem failed for out %u (%d)\n", i, ret);
            return -1;
        }
    }

    /* Post-processing template and mappings */
    for (int k = 0; k < 9; k++) {
        int out_idx = find_output_index(g_output_attrs, 9, k_canonical_output_names[k], k);
        if (out_idx < 0) {
            fprintf(stderr, "error: canonical output '%s' not found\n", k_canonical_output_names[k]);
            return -1;
        }
        g_out_idx_map[k] = out_idx;
        const rknn_tensor_attr *attr = &g_output_attrs[out_idx];

        if (attr->fmt == RKNN_TENSOR_NCHW) {
            uint32_t h = attr->dims[2], w = attr->dims[3];
            g_post_tensors_template[k].n_channels = (int32_t)attr->dims[1];
            g_post_tensors_template[k].channel_stride = (int32_t)(h * w);
            g_post_tensors_template[k].row_stride = (int32_t)w;
            g_post_tensors_template[k].col_stride = 1;
        } else {
            uint32_t w = attr->dims[2], c = attr->dims[3];
            g_post_tensors_template[k].n_channels = (int32_t)attr->dims[3];
            g_post_tensors_template[k].row_stride = (int32_t)(w * c);
            g_post_tensors_template[k].col_stride = (int32_t)c;
            g_post_tensors_template[k].channel_stride = 1;
        }
    }

    npu_post_config_init(&g_post_cfg);
    g_post_cfg.conf_thres = g_cfg.conf_thres;
    g_post_cfg.max_det = 300;

    /* Triple input buffers 0, 1, and 2 */
    size_t in_size = 960u * 320u * 3u;
    if (alloc_dma_buf(&g_bufs[0], in_size) < 0 ||
        alloc_dma_buf(&g_bufs[1], in_size) < 0 ||
        alloc_dma_buf(&g_bufs[2], in_size) < 0) {
        fprintf(stderr, "error: failed to allocate triple DMA input buffers\n");
        return -1;
    }

    pthread_mutex_init(&g_nom.mutex, NULL);
    pthread_condattr_t cattr;
    pthread_condattr_init(&cattr);
    pthread_condattr_setclock(&cattr, CLOCK_MONOTONIC);
    pthread_cond_init(&g_nom.cond, &cattr);
    pthread_condattr_destroy(&cattr);
    memset(g_nom.slots, 0, sizeof(g_nom.slots));
    g_nom.slots[0].state = REQ_IDLE;
    g_nom.slots[1].state = REQ_IDLE;
    g_nom.next_seq = 0;
    g_slot_order_count = 0;
    for (int i = 0; i < 4; i++) g_ch_nominated[i] = 0;

    g_last_text_ns = now_ns();
    g_stop = 0;
    g_inited = 1;

    if (pthread_create(&g_worker_thread, NULL, npu_worker_thread, NULL) != 0) {
        perror("pthread_create npu_worker_thread");
        return -1;
    }

    return 0;
}

void qnpu_register(int ch, int src_w, int src_h)
{
    if (ch < 0 || ch >= 4) return;
    pthread_mutex_lock(&g_reg_mutex);
    g_src_w[ch] = src_w;
    g_src_h[ch] = src_h;
    quad_calc_band_rect(src_w, src_h, &g_band_rects[ch]);
    g_ch_registered[ch] = true;
    g_valid_mask |= (1u << ch);
    quad_swrr_set_mask(&g_swrr, g_valid_mask);
    pthread_mutex_unlock(&g_reg_mutex);
}

void qnpu_offer(int ch, const QnpuSrc *src)
{
    if (ch < 0 || ch >= 4 || !src) return;
    if (!__atomic_load_n(&g_ch_nominated[ch], __ATOMIC_ACQUIRE)) {
        return;
    }

    pthread_mutex_lock(&g_nom.mutex);
    int slot_idx = -1;
    for (int i = 0; i < 2; i++) {
        if (g_nom.slots[i].state == REQ_NOMINATED && g_nom.slots[i].ch == ch) {
            slot_idx = i;
            break;
        }
    }
    if (slot_idx < 0) {
        pthread_mutex_unlock(&g_nom.mutex);
        return;
    }
    qnpu_slot_t *slot = &g_nom.slots[slot_idx];
    uint64_t offer_seq = slot->req_seq;
    slot->state = REQ_FILLING;
    __atomic_store_n(&g_ch_nominated[ch], 0, __ATOMIC_RELEASE);
    int target_buf = slot->buf_idx;
    pthread_mutex_unlock(&g_nom.mutex);

    qnpu_rga_crop(ch, src, target_buf);

    pthread_mutex_lock(&g_nom.mutex);
    if (slot->req_seq != offer_seq || slot->state == REQ_CANCELLED) {
        if (slot->req_seq == offer_seq) {
            slot->state = REQ_IDLE;
        }
        pthread_cond_broadcast(&g_nom.cond);
        pthread_mutex_unlock(&g_nom.mutex);
        return;
    }
    slot->frame_id = src->frame_id;
    slot->timestamp_ns = now_ns();
    slot->state = REQ_READY;
    pthread_cond_broadcast(&g_nom.cond);
    pthread_mutex_unlock(&g_nom.mutex);
}

void qnpu_stats_line(char *buf, size_t n)
{
    if (!buf || n == 0) return;
    pthread_mutex_lock(&g_stats_mutex);
    double run_avg = g_run_count ? ((double)g_run_sum_ns / (double)g_run_count / 1e6) : 0.0;
    double bind_avg = g_bind_count ? ((double)g_bind_sum_ns / (double)g_bind_count / 1e6) : 0.0;
    double wait_avg = g_wait_count ? ((double)g_wait_sum_ns / (double)g_wait_count / 1e6) : 0.0;
    int total_to = g_timeouts[0] + g_timeouts[1] + g_timeouts[2] + g_timeouts[3];

    snprintf(buf, n, "NPU total: %.1ffps [0:%.1f 1:%.1f 2:%.1f 3:%.1f] run:%.2fms bind:%.2fms wait:%.2fms to:%d (0:%d 1:%d 2:%d 3:%d)",
             g_total_fps,
             g_ch_fps[0], g_ch_fps[1], g_ch_fps[2], g_ch_fps[3],
             run_avg, bind_avg, wait_avg, total_to,
             g_timeouts[0], g_timeouts[1], g_timeouts[2], g_timeouts[3]);
    pthread_mutex_unlock(&g_stats_mutex);
}

void qnpu_stop(void)
{
    if (!g_inited) return;
    g_stop = 1;

    pthread_mutex_lock(&g_nom.mutex);
    pthread_cond_broadcast(&g_nom.cond);
    pthread_mutex_unlock(&g_nom.mutex);

    pthread_join(g_worker_thread, NULL);

    pthread_mutex_lock(&g_box_mutex);
    for (int i = 0; i < 4; i++) {
        g_last_box_count[i] = 0;
    }
    pthread_mutex_unlock(&g_box_mutex);

    if (g_bar1) {
        for (uint32_t i = 0; i < 32; i++) {
            g_bar1[(0x900u + i * 4) / 4] = 0;
        }
        for (uint32_t i = 0; i < 16; i++) {
            g_bar1[(0xC80u + i * 4) / 4] = 0x20202020u;
        }
    }

    for (uint32_t i = 0; i < 9; i++) {
        if (g_zc_output_mems[i]) {
            rknn_destroy_mem(g_ctx, g_zc_output_mems[i]);
            g_zc_output_mems[i] = NULL;
        }
    }

    for (int i = 0; i < 3; i++) {
        if (g_bufs[i].zc_mem) {
            rknn_destroy_mem(g_ctx, g_bufs[i].zc_mem);
            g_bufs[i].zc_mem = NULL;
        }
        if (g_bufs[i].rga_handle > 0) {
            releasebuffer_handle(g_bufs[i].rga_handle);
            g_bufs[i].rga_handle = 0;
        }
        if (g_bufs[i].va && g_bufs[i].va != MAP_FAILED) {
            munmap(g_bufs[i].va, g_bufs[i].len);
            g_bufs[i].va = NULL;
        }
        if (g_bufs[i].fd >= 0) {
            close(g_bufs[i].fd);
            g_bufs[i].fd = -1;
        }
    }

    if (g_ctx) {
        rknn_destroy(g_ctx);
        g_ctx = 0;
    }

    pthread_mutex_destroy(&g_nom.mutex);
    pthread_cond_destroy(&g_nom.cond);
    g_inited = 0;
}

int qnpu_get_boxes(int ch, npu_det_t *out, int max)
{
    if (ch < 0 || ch >= 4 || !out || max <= 0) {
        return 0;
    }
    pthread_mutex_lock(&g_box_mutex);
    int cnt = g_last_box_count[ch];
    if (cnt > max) cnt = max;
    for (int i = 0; i < cnt; i++) {
        out[i] = g_last_boxes[ch][i];
    }
    pthread_mutex_unlock(&g_box_mutex);
    return cnt;
}

int qnpu_direct_infer(const void *rgb_data, int ch,
                      npu_det_t *band_dets, npu_det_t *screen_dets,
                      int *num_dets, double *run_ms)
{
    if (!rgb_data || !g_inited || ch < 0 || ch >= 4) return -1;
    memcpy(g_bufs[0].va, rgb_data, 960 * 320 * 3);

    rknn_tensor_attr in_attr = g_input_attrs[0];
    in_attr.type = RKNN_TENSOR_UINT8;
    in_attr.fmt = RKNN_TENSOR_NHWC;
    in_attr.pass_through = 0;

    int ret = rknn_set_io_mem(g_ctx, g_bufs[0].zc_mem, &in_attr);
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "error: direct_infer rknn_set_io_mem failed (%d)\n", ret);
        return -1;
    }

    uint64_t t0 = now_ns();
    ret = rknn_run(g_ctx, NULL);
    uint64_t t1 = now_ns();
    if (run_ms) {
        *run_ms = (double)(t1 - t0) / 1e6;
    }
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "error: direct_infer rknn_run failed (%d)\n", ret);
        return -1;
    }

    npu_tensor_t post_tensors[9];
    for (int k = 0; k < 9; k++) {
        int out_idx = g_out_idx_map[k];
        post_tensors[k] = g_post_tensors_template[k];
        post_tensors[k].data = g_zc_output_mems[out_idx]->virt_addr;
        post_tensors[k].scale = g_output_attrs[out_idx].scale;
        post_tensors[k].zp = g_output_attrs[out_idx].zp;
    }

    npu_det_t raw_dets[300];
    int n = npu_post_process_9tensors_int8(&g_post_cfg, post_tensors, raw_dets, 300);

    if (num_dets) *num_dets = n;
    for (int i = 0; i < n; i++) {
        if (band_dets) band_dets[i] = raw_dets[i];
        if (screen_dets) quad_band_to_screen_det(ch, &raw_dets[i], &screen_dets[i]);
    }
    return 0;
}


