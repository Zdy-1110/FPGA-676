#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>

#include "quad_npu.h"
#include "quad_sched.h"

static void print_usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [options]\n"
            "Options:\n"
            "  --bar1 HEX         Physical address of BAR1 (e.g. 0xf0204000)\n"
            "  --model PATH       Path to RKNN model file (e.g. models/npu/b5_v6n_band.rknn)\n"
            "  --rgb FILE         Path to raw 960x320 RGB888 image file (921600 bytes)\n"
            "  --ch N             Channel index (0..3, default 0)\n"
            "  --loops K          Inference benchmark loop count (default 1)\n"
            "  --conf THRES       Detection confidence threshold (default 0.25)\n"
            "  -h, --help         Show this help\n",
            prog);
}

int main(int argc, char *argv[])
{
    uint32_t bar1_hex = 0;
    const char *model_path = NULL;
    const char *rgb_path = NULL;
    int ch = 0;
    int loops = 1;
    float conf_thres = 0.25f;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--bar1") && i + 1 < argc) {
            bar1_hex = (uint32_t)strtoul(argv[++i], NULL, 16);
        } else if (!strcmp(argv[i], "--model") && i + 1 < argc) {
            model_path = argv[++i];
        } else if (!strcmp(argv[i], "--rgb") && i + 1 < argc) {
            rgb_path = argv[++i];
        } else if (!strcmp(argv[i], "--ch") && i + 1 < argc) {
            ch = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--loops") && i + 1 < argc) {
            loops = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--conf") && i + 1 < argc) {
            conf_thres = (float)atof(argv[++i]);
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown or incomplete option: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }

    if (!model_path || !rgb_path) {
        fprintf(stderr, "Error: --model and --rgb are required.\n");
        print_usage(argv[0]);
        return 1;
    }

    if (ch < 0 || ch >= 4) {
        fprintf(stderr, "Error: --ch must be in range 0..3 (got %d)\n", ch);
        return 1;
    }
    if (loops < 1) loops = 1;

    /* Read RGB file */
    FILE *fp = fopen(rgb_path, "rb");
    if (!fp) {
        fprintf(stderr, "Error: cannot open rgb file '%s'\n", rgb_path);
        return 1;
    }
    fseek(fp, 0, SEEK_END);
    long rgb_size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (rgb_size != 921600) {
        fprintf(stderr, "Error: rgb file size (%ld) != 921600 bytes (960x320x3)\n", rgb_size);
        fclose(fp);
        return 1;
    }
    void *rgb_buf = malloc(921600);
    if (!rgb_buf) {
        fclose(fp);
        return 1;
    }
    if (fread(rgb_buf, 1, 921600, fp) != 921600) {
        fprintf(stderr, "Error: failed to read rgb data\n");
        free(rgb_buf);
        fclose(fp);
        return 1;
    }
    fclose(fp);

    /* Map BAR1 if specified */
    int mem_fd = -1;
    void *bar1_map = NULL;
    volatile uint32_t *bar1 = NULL;
    if (bar1_hex > 0) {
        mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
        if (mem_fd < 0) {
            perror("warning: open /dev/mem failed");
        } else {
            bar1_map = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, bar1_hex);
            if (bar1_map == MAP_FAILED) {
                perror("warning: mmap BAR1 failed");
                bar1_map = NULL;
            } else {
                bar1 = (volatile uint32_t *)bar1_map;
                printf("Mapped BAR1 at physical 0x%08X to virtual %p\n", bar1_hex, bar1_map);
            }
        }
    }

    /* Initialize QNPU */
    QnpuCfg cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.model_path = model_path;
    cfg.conf_thres = conf_thres;
    cfg.weights[0] = 2;
    cfg.weights[1] = 1;
    cfg.weights[2] = 1;
    cfg.weights[3] = 1;
    cfg.dump_n = 0;

    printf("Initializing NPU with model '%s'...\n", model_path);
    if (qnpu_init(&cfg, bar1) < 0) {
        fprintf(stderr, "Error: qnpu_init failed\n");
        if (bar1_map) munmap(bar1_map, 4096);
        if (mem_fd >= 0) close(mem_fd);
        free(rgb_buf);
        return 1;
    }

    /* Run inference */
    npu_det_t band_dets[300];
    npu_det_t screen_dets[300];
    int num_dets = 0;
    double total_run_ms = 0.0;

    printf("Executing %d inference loop(s) for channel %d...\n", loops, ch);
    for (int i = 0; i < loops; i++) {
        double run_ms = 0.0;
        int ret = qnpu_direct_infer(rgb_buf, ch, band_dets, screen_dets, &num_dets, &run_ms);
        if (ret < 0) {
            fprintf(stderr, "Error: qnpu_direct_infer failed on iteration %d\n", i);
            break;
        }
        total_run_ms += run_ms;
    }
    double avg_run_ms = loops > 0 ? (total_run_ms / (double)loops) : 0.0;
    printf("Inference finished. Average run time: %.2f ms (over %d loops)\n", avg_run_ms, loops);

    /* Print detection results */
    printf("Found %d detections (conf >= %.2f):\n", num_dets, conf_thres);
    for (int i = 0; i < num_dets; i++) {
        printf("  #%02d cls=%d score=%.4f band=[%.1f, %.1f, %.1f, %.1f] screen=[%.1f, %.1f, %.1f, %.1f]\n",
               i, band_dets[i].cls, band_dets[i].score,
               band_dets[i].x0, band_dets[i].y0, band_dets[i].x1, band_dets[i].y1,
               screen_dets[i].x0, screen_dets[i].y0, screen_dets[i].x1, screen_dets[i].y1);
    }

    /* Select top 4 boxes */
    npu_det_t top4[4];
    int n4 = quad_select_top4(band_dets, num_dets, conf_thres, top4);
    npu_det_t screen_top4[4];
    for (int k = 0; k < n4; k++) {
        quad_band_to_screen_det(ch, &top4[k], &screen_top4[k]);
    }
    uint32_t regs[8];
    quad_pack_ch_regs(screen_top4, n4, regs);

    if (bar1) {
        printf("Writing %d boxes to BAR1 OSD registers for channel %d...\n", n4, ch);
        for (int k = 0; k < 4; k++) {
            uint32_t off_low = 0x900u + (uint32_t)((ch * 4 + k) * 8);
            uint32_t off_high = off_low + 4u;
            /* High word first, low word second */
            bar1[off_high / 4] = regs[2 * k + 1];
            bar1[off_low / 4]  = regs[2 * k + 0];
            printf("  Box %d: [high 0x%03X]=0x%08X  [low 0x%03X]=0x%08X\n",
                   k, off_high, regs[2 * k + 1], off_low, regs[2 * k + 0]);
        }

        printf("Waiting 5 seconds before clearing OSD boxes...\n");
        sleep(5);

        printf("Clearing OSD boxes for channel %d (writing 0 to 4 low words)...\n", ch);
        for (int k = 0; k < 4; k++) {
            uint32_t off_low = 0x900u + (uint32_t)((ch * 4 + k) * 8);
            bar1[off_low / 4] = 0;
        }
        printf("OSD boxes cleared.\n");
    } else {
        printf("Notice: BAR1 not mapped; skipping hardware register writes.\n");
    }

    qnpu_stop();

    if (bar1_map) munmap(bar1_map, 4096);
    if (mem_fd >= 0) close(mem_fd);
    free(rgb_buf);

    return 0;
}
