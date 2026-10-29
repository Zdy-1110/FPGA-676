/*
 * ADAS 驾驶状态基线逻辑：
 * FPGA (fpga/src/disp/rt_osd_ctl.v:318-339) 将物理按键直接映射为驾驶状态：
 *   KEY0 短按: 自车车道循环切换 (lane 0->1->2->0)
 *   KEY1 短按: 行驶/停止切换 (moving 0<->1)
 *   KEY2/KEY3: 转向请求；KEY4: 显示模式/信号源/cal_mode
 * 菜单程序 (menu_daemon / usb_menu) 同样复用 KEY0 (移动光标) 与 KEY1 (确认/选中)。
 * 用户在浏览菜单时会无意中改写 FPGA 内部的 lane 与 moving 寄存器状态 (经 0x848 回读)。
 * 导致进入视频播放后 ADAS 读取到被菜单污染的 moving/lane，从而产生误报（如误判闯红灯）。
 *
 * 为此引入基线逻辑 (g_lane_base / g_moving_base)：
 * 1. 初值由环境变量 ADAS_LANE_BASE / ADAS_MOVING_BASE 读取，缺省 -1 表示未定；
 * 2. 首次采样若基线仍为 -1，则以当前 0x848 raw 状态为基线，首帧生效值置为 lane=1 (直行)、moving=0 (停止)；
 * 3. 运行期间支持 SIGUSR1 信号触发重新采样基线 (rebaseline)；
 * 4. ADAS 所有决策与 OSD 显示均使用相对基线的生效状态 (lane_eff / moving_eff)。
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include "im2d.h"
#include "RgaApi.h"
#include "tl_det.h"
#include "adas.h"

#if defined(__has_include) && __has_include(<linux/dma-heap.h>)
#include <linux/dma-heap.h>
#else
struct dma_heap_allocation_data {
    uint64_t len;
    uint32_t fd;
    uint32_t fd_flags;
    uint64_t heap_flags;
};
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)
#endif

#define ADAS_WIDTH  1920
#define ADAS_HEIGHT 648
#define ADAS_BGR_SIZE (ADAS_WIDTH * ADAS_HEIGHT * 3)

static volatile uint32_t *g_bar1 = NULL;
static int g_enabled = 0;
static int g_running = 0;
static pthread_t g_thread;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;

static int g_dma_fd = -1;
static size_t g_dma_len = 0;
static void *g_bgr_va = NULL;
static rga_buffer_handle_t g_bgr_handle = 0;

static int g_busy = 0;
static int g_new_frame = 0;
static uint64_t g_frame_id = 0;

static tl_params_t g_tl_params;
static tl_filter_t g_tl_filter;

static double g_adas_fps = 0.0;
static int g_adas_processed_frames = 0;
static int g_last_sig[3] = { 0, 0, 0 };
static int g_last_dec = 0;

static int g_lane_base = -1;
static int g_moving_base = -1;
static volatile sig_atomic_t g_rebaseline = 0;

static void adas_sigusr1_handler(int sig)
{
    (void)sig;
    g_rebaseline = 1;
}

static int alloc_dma_bgr_buf(void)
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
            perror("ADAS: open /dev/dma_heap/cma and system");
            return -1;
        }
    }

    g_dma_len = (ADAS_BGR_SIZE + 4095u) & ~(size_t)4095u;
    memset(&data, 0, sizeof(data));
    data.len = g_dma_len;
    data.fd_flags = O_RDWR | O_CLOEXEC;
    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) {
        perror("ADAS: DMA_HEAP_IOCTL_ALLOC");
        close(hfd);
        return -1;
    }
    close(hfd);
    g_dma_fd = data.fd;

    g_bgr_va = mmap(NULL, g_dma_len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, g_dma_fd, 0);
    if (g_bgr_va == MAP_FAILED) {
        perror("ADAS: mmap dma buf");
        close(g_dma_fd);
        g_dma_fd = -1;
        g_bgr_va = NULL;
        return -1;
    }

    memset(&dst_param, 0, sizeof(dst_param));
    dst_param.width = ADAS_WIDTH;
    dst_param.height = ADAS_HEIGHT;
    dst_param.format = RK_FORMAT_BGR_888;
    g_bgr_handle = importbuffer_fd(g_dma_fd, &dst_param);
    if (g_bgr_handle <= 0) {
        fprintf(stderr, "ADAS: importbuffer_fd failed: %d\n", g_bgr_handle);
        munmap(g_bgr_va, g_dma_len);
        g_bgr_va = NULL;
        close(g_dma_fd);
        g_dma_fd = -1;
        return -1;
    }
    return 0;
}

static void free_dma_bgr_buf(void)
{
    if (g_bgr_handle > 0) {
        releasebuffer_handle(g_bgr_handle);
        g_bgr_handle = 0;
    }
    if (g_bgr_va && g_bgr_va != MAP_FAILED) {
        munmap(g_bgr_va, g_dma_len);
        g_bgr_va = NULL;
    }
    if (g_dma_fd >= 0) {
        close(g_dma_fd);
        g_dma_fd = -1;
    }
}

void adas_offer(int ch, const QnpuSrc *src)
{
    if (!g_running || !g_enabled || ch != 0 || !src) return;

    pthread_mutex_lock(&g_mutex);
    if (g_busy || g_new_frame) {
        pthread_mutex_unlock(&g_mutex);
        return;
    }
    g_busy = 1;
    pthread_mutex_unlock(&g_mutex);

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
        pthread_mutex_lock(&g_mutex);
        g_busy = 0;
        pthread_mutex_unlock(&g_mutex);
        return;
    }

    int crop_w = src->width < ADAS_WIDTH ? src->width : ADAS_WIDTH;
    int crop_h = src->height < ADAS_HEIGHT ? src->height : ADAS_HEIGHT;
    im_rect srect = { 0, 0, crop_w, crop_h };
    im_rect drect = { 0, 0, ADAS_WIDTH, ADAS_HEIGHT };
    rga_buffer_t pat = { 0 };
    im_rect prect = { 0 };

    rga_buffer_t dst = wrapbuffer_handle(g_bgr_handle, ADAS_WIDTH, ADAS_HEIGHT, RK_FORMAT_BGR_888, ADAS_WIDTH, ADAS_HEIGHT);
    rga_buffer_t rga_src = wrapbuffer_handle(src_handle, src->width, src->height, fmt, src->wstride, src->hstride);
    rga_src.color_space_mode = IM_YUV_TO_RGB_BT601_LIMIT;
    dst.color_space_mode = IM_YUV_TO_RGB_BT601_LIMIT;

    improcess(rga_src, dst, pat, srect, drect, prect, 0);

    if (need_release && src_handle > 0) {
        releasebuffer_handle(src_handle);
    }

    pthread_mutex_lock(&g_mutex);
    g_new_frame = 1;
    g_frame_id = src->frame_id;
    pthread_cond_signal(&g_cond);
    pthread_mutex_unlock(&g_mutex);
}

static const char *tl_str_abbr(int s) {
    if (s == TL_COLOR_RED) return "RED";
    if (s == TL_COLOR_YELLOW) return "YEL";
    if (s == TL_COLOR_GREEN) return "GRN";
    return "-- ";
}

static void *adas_thread(void *arg)
{
    (void)arg;
    tl_box_t boxes[64];
    int raw3[3];
    char text[64];

    while (g_running) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 1;
        pthread_mutex_lock(&g_mutex);
        while (g_running && !g_new_frame) {
            if (pthread_cond_timedwait(&g_cond, &g_mutex, &ts) != 0) break;
        }
        if (!g_running) { pthread_mutex_unlock(&g_mutex); break; }
        if (!g_new_frame) { pthread_mutex_unlock(&g_mutex); continue; }
        g_new_frame = 0;
        pthread_mutex_unlock(&g_mutex);

        const uint8_t *bgr = (const uint8_t *)g_bgr_va;
        int n = tl_detect(bgr, ADAS_WIDTH, ADAS_HEIGHT, &g_tl_params, boxes, 64);
        tl_associate(boxes, n, raw3);

        if (g_bar1) {
            uint32_t drv = g_bar1[0x848u / 4];
            int raw_lane = (int)(drv & 3u);
            if (raw_lane > 2) raw_lane = 2;
            int raw_moving = (int)((drv >> 2) & 1u);
            int lreq = (drv >> 3) & 1;
            int rreq = (drv >> 4) & 1;

            int lane_eff;
            int moving_eff;

            if (g_rebaseline) {
                g_rebaseline = 0;
                g_lane_base = raw_lane;
                g_moving_base = raw_moving;
                lane_eff = 1;
                moving_eff = 0;
                fprintf(stderr, "adas: rebaseline lane=%d moving=%d\n", g_lane_base, g_moving_base);
            } else if (g_lane_base < 0 || g_moving_base < 0) {
                if (g_lane_base < 0) g_lane_base = raw_lane;
                if (g_moving_base < 0) g_moving_base = raw_moving;
                lane_eff = 1;
                moving_eff = 0;
                fprintf(stderr, "adas: baseline lane=%d moving=%d\n", g_lane_base, g_moving_base);
            } else {
                /* 基线视为直行，KEY0 每按一次相对偏移一格；这样菜单浏览期间的按键不会改变开播瞬间的车道语义 */
                lane_eff = (raw_lane - g_lane_base + 1 + 3) % 3;
                moving_eff = raw_moving ^ g_moving_base;
            }

            tl_filter_update(&g_tl_filter, raw3, !moving_eff, g_last_sig);

            uint32_t ls = g_bar1[0x8D0u / 4];
            uint32_t rs = g_bar1[0x8DCu / 4];
            int lvalid = ls & 1, lsolid = (ls >> 1) & 1;
            int rvalid = rs & 1, rsolid = (rs >> 1) & 1;
            int force = (g_bar1[0x8E8u / 4] >> 21) & 1;

            npu_det_t ch0_boxes[4];
            int n_boxes = qnpu_get_boxes(0, ch0_boxes, 4);
            int hazard = 0;
            for (int i = 0; i < n_boxes; i++) {
                const npu_det_t *b = &ch0_boxes[i];
                if (b->cls == 0 || b->cls == 1 || b->cls == 6) {
                    if (b->score >= 0.30f && b->y1 >= 0.75f * 540.0f) {
                        float cx = (b->x0 + b->x1) * 0.5f;
                        if (cx >= 0.30f * 960.0f && cx <= 0.70f * 960.0f) {
                            hazard = 1;
                            break;
                        }
                    }
                }
            }

            uint32_t dec = 0;
            if (hazard) {
                dec = (3u << (2 * lane_eff)) | (1u << 8);
            } else {
                int sig = (lane_eff >= 0 && lane_eff < 3) ? g_last_sig[lane_eff] : 0;
                if (sig == 1 || sig == 2) {
                    dec |= (3u << (2 * lane_eff));
                    if (moving_eff) dec |= (1u << 8);
                } else if (sig == 3) {
                    dec |= (2u << (2 * lane_eff));
                } else {
                    dec |= (2u << (2 * 1));
                }

                if (lreq && lvalid) {
                    if (!lsolid) dec = (dec & ~0x3u) | 2u;
                    else if (force) { dec = (dec & ~0x3u) | 3u; dec |= (1u << 8); }
                }
                if (rreq && rvalid) {
                    if (!rsolid) dec = (dec & ~(3u << 4)) | (2u << 4);
                    else if (force) { dec = (dec & ~(3u << 4)) | (3u << 4); dec |= (1u << 8); }
                }
            }

            g_bar1[0x8C0u / 4] &= ~4u;
            g_bar1[0x850u / 4] = dec;
            g_last_dec = dec;

            char ln_ch = (lane_eff == 0) ? 'L' : ((lane_eff == 2) ? 'R' : 'S');
            memset(text, ' ', sizeof(text));
            snprintf(text, sizeof(text), "L:%s S:%s R:%s LN:%c MOV:%d HZ:%d B:%d%d",
                     tl_str_abbr(g_last_sig[0]), tl_str_abbr(g_last_sig[1]),
                     tl_str_abbr(g_last_sig[2]), ln_ch, moving_eff, hazard,
                     raw_lane, raw_moving);
            int len = strlen(text);
            if (len < 64) text[len] = ' ';
            for (int i = 0; i < 16; i++) {
                uint32_t val = (uint8_t)text[i * 4 + 0] |
                               ((uint8_t)text[i * 4 + 1] << 8) |
                               ((uint8_t)text[i * 4 + 2] << 16) |
                               ((uint8_t)text[i * 4 + 3] << 24);
                g_bar1[(0xCC0u + (uint32_t)(i * 4)) / 4] = val;
            }
        }

        pthread_mutex_lock(&g_mutex);
        g_busy = 0;
        g_adas_processed_frames++;
        pthread_mutex_unlock(&g_mutex);
    }
    return NULL;
}

int adas_init(volatile uint32_t *bar1, const char *cfg_path)
{
    (void)cfg_path;
    g_bar1 = bar1;
    tl_params_default(&g_tl_params);
    g_tl_params.roi_y_max_frac = 1.0;
    tl_filter_init(&g_tl_filter, &g_tl_params, 10.0);

    g_lane_base = -1;
    g_moving_base = -1;
    const char *env_lane = getenv("ADAS_LANE_BASE");
    if (env_lane && *env_lane) {
        int v = atoi(env_lane);
        if (v >= 0 && v <= 2) {
            g_lane_base = v;
        }
    }
    const char *env_mov = getenv("ADAS_MOVING_BASE");
    if (env_mov && *env_mov) {
        int v = atoi(env_mov);
        if (v >= 0 && v <= 1) {
            g_moving_base = v;
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = adas_sigusr1_handler;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGUSR1, &sa, NULL);

    if (alloc_dma_bgr_buf() != 0) {
        fprintf(stderr, "ADAS: CMA buffer allocation failed, ADAS disabled\n");
        return -1;
    }

    g_running = 1;
    g_enabled = 1;
    if (pthread_create(&g_thread, NULL, adas_thread, NULL) != 0) {
        perror("ADAS: pthread_create failed");
        free_dma_bgr_buf();
        g_running = 0;
        g_enabled = 0;
        return -1;
    }
    return 0;
}

void adas_stop(void)
{
    if (!g_running) return;
    g_running = 0;
    g_enabled = 0;
    pthread_mutex_lock(&g_mutex);
    pthread_cond_broadcast(&g_cond);
    pthread_mutex_unlock(&g_mutex);
    pthread_join(g_thread, NULL);
    free_dma_bgr_buf();
}

void adas_stats_line(char *buf, size_t max_len)
{
    if (!buf || max_len == 0) return;
    pthread_mutex_lock(&g_mutex);
    snprintf(buf, max_len, "adas: %s, frames=%d, fps=%.1f, sig=%d/%d/%d, dec=0x%03x",
             g_enabled ? "on" : "off", g_adas_processed_frames, g_adas_fps,
             g_last_sig[0], g_last_sig[1], g_last_sig[2], g_last_dec);
    pthread_mutex_unlock(&g_mutex);
}
