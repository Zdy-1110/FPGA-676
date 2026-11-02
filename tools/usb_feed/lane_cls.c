#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>

#include "lane_cls.h"

/*
 * 环境变量与参数说明（全部整数运算）：
 * 1. ADAS_LANE_CLS: 分类模式选择。
 *    - "fpga": 默认模式，直接透传 FPGA 24 帧表决出的 valid/solid，用于基线对照。
 *    - "win" : RK 窗口分位数时序分类器。
 * 2. ADAS_LANE_W: 窗口大小 (帧数)，默认 30 (范围 1~64)。
 *    - 在 30fps 下约 1.0s，50fps 下约 0.6s。虚线周期通常为 20~30 帧，30 帧可完整覆盖虚线周期的波谷。
 * 3. ADAS_LANE_TON: 进入实线门限 (行数)，默认 60 (范围 1~255)。
 *    - 对应 RTL solid_rows 默认 61。当窗口内分位数持续达到 60 时进入实线。
 * 4. ADAS_LANE_TOFF: 退出实线门限 (行数)，默认 40 (范围 1~255)。
 *    - 虚线间隙期 max_consec 通常降至 20 左右，低于 40 即可稳定退出实线。
 *    - 与 T_ON 构成 20 行滞回区间，防止在临界值附近反复抖动。
 * 5. ADAS_LANE_P: 分位数百分比，默认 10 (范围 0~100)。
 *    - P=0 为严格最小值。P=10 取 10% 分位数，在 30 帧窗口中允许 1~2 帧毛刺噪声，提升鲁棒性。
 */

enum {
    LANE_CLS_MODE_FPGA = 0,
    LANE_CLS_MODE_WIN  = 1,
    LANE_CLS_MODE_BUCKET = 2,   /* 11-02 左右非对称漏桶，exp_temporal_20261102.md 方案 (e) */
};

static volatile uint32_t *s_bar1 = NULL;
static pthread_t s_thread;
static volatile int s_running = 0;
static pthread_mutex_t s_mutex = PTHREAD_MUTEX_INITIALIZER;

static int s_out_ready = 0;
static int s_out_lvalid = 0;
static int s_out_lsolid = 0;
static int s_out_rvalid = 0;
static int s_out_rsolid = 0;

static int s_mode = LANE_CLS_MODE_FPGA;
static char s_mode_str[16] = "fpga";
static int s_lane_w = 30;
static int s_lane_ton = 60;
static int s_lane_toff = 40;
static int s_lane_p = 10;

static LaneSample s_ring[LANE_RING_SIZE];
static int s_ring_head = 0;
static int s_ring_count = 0;

static LaneSide s_side_l;
static LaneSide s_side_r;
static uint32_t s_total_frames = 0;
static uint32_t s_drop_frames = 0;

uint32_t lane_cls_calc_drop(uint8_t cur_fc, uint8_t last_fc)
{
    uint8_t diff = (uint8_t)(cur_fc - last_fc);
    return (diff > 1) ? (uint32_t)(diff - 1) : 0;
}

#ifdef LANE_CLS_TEST
void lane_cls_test_init(const char *mode, int w, int ton, int toff, int p)
{
    if (mode && strcmp(mode, "win") == 0) {
        s_mode = LANE_CLS_MODE_WIN;
        snprintf(s_mode_str, sizeof(s_mode_str), "win");
    } else if (mode && strcmp(mode, "bucket") == 0) {
        s_mode = LANE_CLS_MODE_BUCKET;
        snprintf(s_mode_str, sizeof(s_mode_str), "bucket");
    } else {
        s_mode = LANE_CLS_MODE_FPGA;
        snprintf(s_mode_str, sizeof(s_mode_str), "fpga");
    }
    s_lane_w = (w > 0 && w <= LANE_RING_SIZE) ? w : 30;
    s_lane_ton = (ton > 0 && ton <= 255) ? ton : 60;
    s_lane_toff = (toff > 0 && toff <= 255) ? toff : 40;
    s_lane_p = (p >= 0 && p <= 100) ? p : 10;
}
#endif

#ifdef LANE_CLS_TEST
void lane_cls_update(LaneSide *s, const LaneSample *ring, int n)
#else
static void lane_cls_update(LaneSide *s, const LaneSample *ring, int n)
#endif
{
    if (!s || !ring || n <= 0) return;

    const LaneSample *cur = &ring[n - 1];
    int fpga_v = (s->side == 0) ? cur->fpga_valid_l : cur->fpga_valid_r;
    int fpga_s = (s->side == 0) ? cur->fpga_solid_l : cur->fpga_solid_r;
    uint8_t mc = (s->side == 0) ? cur->max_consec_l : cur->max_consec_r;
    uint8_t dbl = (s->side == 0) ? cur->double_cnt_l : cur->double_cnt_r;

    s->last_mc = mc;
    s->last_dbl = dbl;

    if (s_mode == LANE_CLS_MODE_BUCKET) {
        /* 左右非对称漏桶（离线 32 用例：虚线 8/12、实线 12/20，基线 2/12、14/20；4 折留一参数一致）
         * 左：mc>=35 则 +5，否则 -3，score>=30 判实；右：mc>=75 则 +3，否则 -5，score>=70 判实；
         * 跟踪无效时清零。参数来源 tools/lane_fpga/exp_temporal_20261102.md */
        s->valid = fpga_v;
        if (!fpga_v) {
            s->score = 0;
            s->solid = 0;
            return;
        }
        int th  = (s->side == 0) ? 35 : 75;
        int up  = (s->side == 0) ? 5 : 3;
        int dn  = (s->side == 0) ? 3 : 5;
        int thr = (s->side == 0) ? 30 : 70;
        if ((int)mc >= th) s->score = (s->score + up > 100) ? 100 : s->score + up;
        else               s->score = (s->score < dn) ? 0 : s->score - dn;
        s->solid = (s->score >= thr) ? 1 : 0;
        return;
    }

    if (s_mode == LANE_CLS_MODE_WIN) {
        s->valid = fpga_v;
        if (!fpga_v) {
            s->solid = 0;
            return;
        }

        int win_len = (n < s_lane_w) ? n : s_lane_w;
        if (win_len <= 0) win_len = 1;

        uint8_t vals[LANE_RING_SIZE];
        int start_idx = n - win_len;
        for (int i = 0; i < win_len; i++) {
            vals[i] = (s->side == 0) ? ring[start_idx + i].max_consec_l
                                     : ring[start_idx + i].max_consec_r;
        }

        /* 简单插入排序（最多 64 项整数，性能极高） */
        for (int i = 1; i < win_len; i++) {
            uint8_t tmp = vals[i];
            int j = i - 1;
            while (j >= 0 && vals[j] > tmp) {
                vals[j + 1] = vals[j];
                j--;
            }
            vals[j + 1] = tmp;
        }

        int stat_val;
        if (s_lane_p <= 0) {
            stat_val = vals[0];
        } else {
            int q_idx = (s_lane_p * (win_len - 1) + 50) / 100;
            if (q_idx < 0) q_idx = 0;
            if (q_idx >= win_len) q_idx = win_len - 1;
            stat_val = vals[q_idx];
        }

        if (stat_val >= s_lane_ton) {
            s->solid = 1;
        } else if (stat_val < s_lane_toff) {
            s->solid = 0;
        }
        /* [T_OFF, T_ON) 滞回区间保持原 s->solid */
    } else {
        /* FPGA 模式透传 */
        s->valid = fpga_v;
        s->solid = fpga_s;
    }
}

static void *lane_cls_thread(void *arg)
{
    (void)arg;
    uint8_t last_fc = 0;
    int has_last_fc = 0;
    struct timespec last_log_ts = {0, 0};
    clock_gettime(CLOCK_MONOTONIC, &last_log_ts);

    while (s_running) {
        usleep(5000); /* 5 ms 采样间隔 */
        if (!s_running) break;

        uint32_t r8e8 = s_bar1[0x8E8u / 4];
        uint8_t fc = (r8e8 >> 24) & 0xFF;

        if (!has_last_fc) {
            has_last_fc = 1;
            last_fc = fc;
            s_total_frames = 1;
        } else {
            if (fc == last_fc) {
                /* 帧未更新，检查日志输出后继续等待 */
                goto check_log;
            }
            uint8_t diff = (uint8_t)(fc - last_fc);
            if (diff > 1) {
                s_drop_frames += (diff - 1);
            }
            s_total_frames += diff;
            last_fc = fc;
        }

        /* 读当前帧原始量与 FPGA 状态 */
        uint32_t r8f4 = s_bar1[0x8F4u / 4];
        uint32_t r8d0 = s_bar1[0x8D0u / 4];
        uint32_t r8dc = s_bar1[0x8DCu / 4];

        LaneSample smp;
        smp.frame_cnt = fc;
        smp.max_consec_r = (r8f4 >> 24) & 0xFF;
        smp.max_consec_l = (r8f4 >> 16) & 0xFF;
        smp.double_cnt_r = (r8f4 >> 8) & 0xFF;
        smp.double_cnt_l = r8f4 & 0xFF;
        smp.fpga_valid_l = r8d0 & 1;
        smp.fpga_solid_l = (r8d0 >> 1) & 1;
        smp.fpga_valid_r = r8dc & 1;
        smp.fpga_solid_r = (r8dc >> 1) & 1;

        /* 压入环形缓冲 */
        s_ring[s_ring_head] = smp;
        s_ring_head = (s_ring_head + 1) % LANE_RING_SIZE;
        if (s_ring_count < LANE_RING_SIZE) {
            s_ring_count++;
        }

        /* 展开为按时序排列的最近 n 项 */
        LaneSample lin_ring[LANE_RING_SIZE];
        int n = s_ring_count;
        for (int i = 0; i < n; i++) {
            int idx = (s_ring_head - n + i + LANE_RING_SIZE) % LANE_RING_SIZE;
            lin_ring[i] = s_ring[idx];
        }

        lane_cls_update(&s_side_l, lin_ring, n);
        lane_cls_update(&s_side_r, lin_ring, n);

        pthread_mutex_lock(&s_mutex);
        s_out_lvalid = s_side_l.valid;
        s_out_lsolid = s_side_l.solid;
        s_out_rvalid = s_side_r.valid;
        s_out_rsolid = s_side_r.solid;
        s_out_ready = 1;
        pthread_mutex_unlock(&s_mutex);

check_log:
        {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long sec_diff = now.tv_sec - last_log_ts.tv_sec;
            long nsec_diff = now.tv_nsec - last_log_ts.tv_nsec;
            if (sec_diff > 1 || (sec_diff == 1 && nsec_diff >= 0)) {
                last_log_ts = now;
                fprintf(stderr,
                        "lanecls: mode=%s frames=%u drop=%u L mc=%u dbl=%u out=%d R mc=%u dbl=%u out=%d\n",
                        s_mode_str, s_total_frames, s_drop_frames,
                        s_side_l.last_mc, s_side_l.last_dbl, s_side_l.solid,
                        s_side_r.last_mc, s_side_r.last_dbl, s_side_r.solid);
                fflush(stderr);
            }
        }
    }

    return NULL;
}

int lane_cls_start(volatile uint32_t *bar1)
{
    if (!bar1) return 0;
    s_bar1 = bar1;

    uint32_t ver = s_bar1[0x838u / 4];
    if (ver < LANE_BITSTREAM_CAM20_VER) {
        return 0;
    }

    if (s_running) {
        lane_cls_stop();
    }

    /* 环境变量解析 */
    const char *env_cls = getenv("ADAS_LANE_CLS");
    if (env_cls && strcmp(env_cls, "win") == 0) {
        s_mode = LANE_CLS_MODE_WIN;
        snprintf(s_mode_str, sizeof(s_mode_str), "win");
    } else if (env_cls && strcmp(env_cls, "bucket") == 0) {
        s_mode = LANE_CLS_MODE_BUCKET;
        snprintf(s_mode_str, sizeof(s_mode_str), "bucket");
    } else {
        s_mode = LANE_CLS_MODE_FPGA;
        snprintf(s_mode_str, sizeof(s_mode_str), "fpga");
    }

    s_lane_w = 30;
    const char *env_w = getenv("ADAS_LANE_W");
    if (env_w && *env_w) {
        int v = atoi(env_w);
        if (v > 0 && v <= LANE_RING_SIZE) s_lane_w = v;
    }

    s_lane_ton = 60;
    const char *env_ton = getenv("ADAS_LANE_TON");
    if (env_ton && *env_ton) {
        int v = atoi(env_ton);
        if (v > 0 && v <= 255) s_lane_ton = v;
    }

    s_lane_toff = 40;
    const char *env_toff = getenv("ADAS_LANE_TOFF");
    if (env_toff && *env_toff) {
        int v = atoi(env_toff);
        if (v > 0 && v <= 255) s_lane_toff = v;
    }

    s_lane_p = 10;
    const char *env_p = getenv("ADAS_LANE_P");
    if (env_p && *env_p) {
        int v = atoi(env_p);
        if (v >= 0 && v <= 100) s_lane_p = v;
    }

    /* 状态与环形缓冲复位 */
    memset(s_ring, 0, sizeof(s_ring));
    s_ring_head = 0;
    s_ring_count = 0;
    s_total_frames = 0;
    s_drop_frames = 0;

    memset(&s_side_l, 0, sizeof(s_side_l));
    s_side_l.side = 0;
    memset(&s_side_r, 0, sizeof(s_side_r));
    s_side_r.side = 1;

    pthread_mutex_lock(&s_mutex);
    s_out_ready = 0;
    s_out_lvalid = 0;
    s_out_lsolid = 0;
    s_out_rvalid = 0;
    s_out_rsolid = 0;
    pthread_mutex_unlock(&s_mutex);

    s_running = 1;
    if (pthread_create(&s_thread, NULL, lane_cls_thread, NULL) != 0) {
        s_running = 0;
        return 0;
    }

    return 1;
}

void lane_cls_stop(void)
{
    if (!s_running) return;
    s_running = 0;
    pthread_join(s_thread, NULL);

    pthread_mutex_lock(&s_mutex);
    s_out_ready = 0;
    pthread_mutex_unlock(&s_mutex);
}

int lane_cls_get(int *lvalid, int *lsolid, int *rvalid, int *rsolid)
{
    /* fpga 模式不替换：adas.c 直接用它当帧读到的 0x8D0/0x8DC，与改动前逐位一致 */
    if (!s_running || s_mode == LANE_CLS_MODE_FPGA) return 0;
    pthread_mutex_lock(&s_mutex);
    if (!s_out_ready) {
        pthread_mutex_unlock(&s_mutex);
        return 0;
    }
    if (lvalid) *lvalid = s_out_lvalid;
    if (lsolid) *lsolid = s_out_lsolid;
    if (rvalid) *rvalid = s_out_rvalid;
    if (rsolid) *rsolid = s_out_rsolid;
    pthread_mutex_unlock(&s_mutex);
    return 1;
}
