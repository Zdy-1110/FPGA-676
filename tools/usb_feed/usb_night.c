#include "usb_night.h"

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

/* 三档参数宏 */
#define NIGHT_LVL0_GAMMA        300
#define NIGHT_LVL0_GAIN         64
#define NIGHT_LVL0_BRIGHTNESS   0
#define NIGHT_LVL0_CONTRAST     32

#define NIGHT_LVL1_GAMMA        350
#define NIGHT_LVL1_GAIN         80
#define NIGHT_LVL1_BRIGHTNESS   16
#define NIGHT_LVL1_CONTRAST     36

#define NIGHT_LVL2_GAMMA        400
#define NIGHT_LVL2_GAIN         96
#define NIGHT_LVL2_BRIGHTNESS   32
#define NIGHT_LVL2_CONTRAST     40

int night_open(const char *dev)
{
    if (!dev || !dev[0]) return -1;
    int fd = open(dev, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "usb_night: failed to open %s for v4l2 ctrl: %s\n", dev, strerror(errno));
        return -1;
    }
    return fd;
}

void night_close(int fd)
{
    if (fd >= 0) {
        close(fd);
    }
}

static int set_ctrl(int fd, __u32 id, __s32 val)
{
    struct v4l2_control c;
    memset(&c, 0, sizeof(c));
    c.id = id;
    c.value = val;
    if (ioctl(fd, VIDIOC_S_CTRL, &c) < 0) {
        return -1;
    }
    return 0;
}

int night_apply(int fd, int level)
{
    if (fd < 0) return -1;

    int gamma, gain, brightness, contrast;

    switch (level) {
    case 1:
        gamma = NIGHT_LVL1_GAMMA;
        gain = NIGHT_LVL1_GAIN;
        brightness = NIGHT_LVL1_BRIGHTNESS;
        contrast = NIGHT_LVL1_CONTRAST;
        break;
    case 2:
        gamma = NIGHT_LVL2_GAMMA;
        gain = NIGHT_LVL2_GAIN;
        brightness = NIGHT_LVL2_BRIGHTNESS;
        contrast = NIGHT_LVL2_CONTRAST;
        break;
    case 0:
    default:
        gamma = NIGHT_LVL0_GAMMA;
        gain = NIGHT_LVL0_GAIN;
        brightness = NIGHT_LVL0_BRIGHTNESS;
        contrast = NIGHT_LVL0_CONTRAST;
        break;
    }

    int ret = 0;
    int err_code = 0;
    if (set_ctrl(fd, V4L2_CID_GAMMA, gamma) < 0) { ret = -1; err_code = errno; }
    if (set_ctrl(fd, V4L2_CID_GAIN, gain) < 0) { ret = -1; err_code = errno; }
    if (set_ctrl(fd, V4L2_CID_BRIGHTNESS, brightness) < 0) { ret = -1; err_code = errno; }
    if (set_ctrl(fd, V4L2_CID_CONTRAST, contrast) < 0) { ret = -1; err_code = errno; }

    if (ret < 0) {
        static int warned = 0;
        if (!warned) {
            warned = 1;
            fprintf(stderr, "usb_night: night_apply failed (level=%d): %s\n",
                    level, strerror(err_code ? err_code : errno));
        }
    }

    return ret;
}

unsigned night_luma(const unsigned char *y, int w, int h, int stride)
{
    if (!y || w <= 0 || h <= 0 || stride <= 0) return 0;

    unsigned long long sum = 0;
    unsigned count = 0;

    for (int r = 0; r < h; r += 8) {
        const unsigned char *row = y + (size_t)r * stride;
        for (int c = 0; c < w; c += 8) {
            sum += row[c];
            count++;
        }
    }

    if (count == 0) return 0;
    return (unsigned)(sum / count);
}

int night_hyst(int *state, int *cnt, unsigned mean, unsigned lo, unsigned hi)
{
    if (!state || !cnt) return 0;

    int cur_state = *state;

    if (cur_state == 0) {
        /* 白天 -> 夜间：亮度低于 lo 且持续 NIGHT_HYST_FRAMES 帧 */
        if (mean < lo) {
            (*cnt)++;
            if (*cnt >= NIGHT_HYST_FRAMES) {
                *state = 1;
                *cnt = 0;
            }
        } else {
            *cnt = 0;
        }
    } else {
        /* 夜间 -> 白天：亮度高于 hi 且持续 NIGHT_HYST_FRAMES 帧 */
        if (mean > hi) {
            (*cnt)++;
            if (*cnt >= NIGHT_HYST_FRAMES) {
                *state = 0;
                *cnt = 0;
            }
        } else {
            *cnt = 0;
        }
    }

    return *state;
}
