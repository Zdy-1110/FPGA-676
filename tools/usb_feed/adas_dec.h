#ifndef ADAS_DEC_H
#define ADAS_DEC_H

#include <stdint.h>

/*
 * adas_lane_signal_dec:
 * 计算非 hazard、无变道请求时的信号决策字 (写入 BAR1 0x850)。
 *
 * lane: 0=左, 1=直, 2=右 (越界按 1 处理)
 * sig[3]: 0=左转灯, 1=直行灯, 2=右转灯 (0=无, 1=红, 2=黄, 3=绿)
 * moving: 0=停, 1=行驶
 *
 * 返回值:
 * [1:0]/[3:2]/[5:4] 为左/直/右箭头编码: 0 灭、1 灰、2 绿、3 红
 * bit8 为全屏告警 (moving 时闯红/黄灯置 1)
 */
static inline uint32_t adas_lane_signal_dec(int lane, const int sig[3], int moving)
{
    if (lane < 0 || lane > 2) {
        lane = 1;
    }

    int s = sig[lane];
    if (s == 0) {
        if (lane == 0) {
            s = sig[1];
        } else if (lane == 2) {
            return (2u << 4); /* 右转不受灯控，右箭头绿，无告警 */
        }
    }

    if (s == 1 || s == 2) {
        return (3u << (2 * lane)) | (moving ? (1u << 8) : 0);
    } else if (s == 3) {
        return (2u << (2 * lane));
    }

    /* 仍为 0 (完全无灯，或直行/左转跟随直行后仍为 0): 直行绿 */
    return (2u << 2);
}

/*
 * adas_box_hazard:
 * 判断单个 NPU 目标框是否触发 hazard 全屏告警。
 *
 * cls: 目标类别 (0=ped, 1=rider, 2=car, 3=truck, 4=bus, 6=cone, 7=barrier, 8=sign)
 * score: 置信度
 * x0, y0, x1, y1: 960x540 坐标格坐标
 * moving: 自车有效行驶状态 (0=停, 1=行驶)
 *
 * 规则:
 * 1. score >= 0.30 且 cx 在 [0.30, 0.70]*960
 * 2. 行人/骑行者/锥桶/路障 (cls 0/1/6/7): 框底 y1 >= 0.75*540 即告警
 * 3. 车辆类 (cls 2/3/4): 需 moving==1 且 y1 >= 0.80*540 且 框宽 (x1-x0) >= 0.20*960
 * 返回 1 表示触发 hazard，0 表示不触发。
 */
static inline int adas_box_hazard(int cls, float score, float x0, float y0, float x1, float y1, int moving)
{
    (void)y0;
    if (score < 0.30f) return 0;

    float cx = (x0 + x1) * 0.5f;
    if (cx < 0.30f * 960.0f || cx > 0.70f * 960.0f) return 0;

    if (cls == 0 || cls == 1 || cls == 6 || cls == 7) {
        return (y1 >= 0.75f * 540.0f) ? 1 : 0;
    }

    if (cls == 2 || cls == 3 || cls == 4) {
        if (!moving) return 0;
        if (y1 < 0.80f * 540.0f) return 0;
        float w = x1 - x0;
        if (w < 0.20f * 960.0f) return 0;
        return 1;
    }

    return 0;
}

#endif /* ADAS_DEC_H */
