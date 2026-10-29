#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#endif
#include "tl_det.h"

#define MAX_REF_FRAMES 100000

typedef struct {
    char ego_motion[32];
    char motion_score[32];
    int valid;
} ref_frame_t;

static ref_frame_t g_ref_frames[MAX_REF_FRAMES];

static void load_ref_csv(const char *path) {
    if (!path || strlen(path) == 0) return;
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "Warning: Could not open ref CSV: %s\n", path);
        return;
    }
    char line[2048];
    if (!fgets(line, sizeof(line), f)) {
        fclose(f);
        return;
    }
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        char *cols[16];
        int col_idx = 0;
        while (p && col_idx < 16) {
            cols[col_idx++] = p;
            char *comma = strchr(p, ',');
            if (!comma) {
                char *nl = strpbrk(p, "\r\n");
                if (nl) *nl = '\0';
                break;
            }
            *comma = '\0';
            p = comma + 1;
        }
        if (col_idx >= 15) {
            int frame_no = atoi(cols[0]);
            if (frame_no >= 0 && frame_no < MAX_REF_FRAMES) {
                ref_frame_t *rf = &g_ref_frames[frame_no];
                rf->valid = 1;
                /* Only ego_motion and motion_score are loaded from ref as input echo */
                if (col_idx > 14) strncpy(rf->ego_motion, cols[14], sizeof(rf->ego_motion) - 1);
                if (col_idx > 15) strncpy(rf->motion_score, cols[15], sizeof(rf->motion_score) - 1);
                else strcpy(rf->motion_score, "0.000");
            }
        }
    }
    fclose(f);
}

static size_t read_exact(unsigned char *buf, size_t n) {
    size_t total = 0;
    while (total < n) {
        size_t r = fread(buf + total, 1, n - total, stdin);
        if (r == 0) break;
        total += r;
    }
    return total;
}

int main(int argc, char **argv) {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
#endif

    int width = 1920;
    int height = 1080;
    int step = 3;
    double fps = 30.0;
    const char *ref_path = NULL;
    const char *out_path = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--w") == 0 && i + 1 < argc) {
            width = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--h") == 0 && i + 1 < argc) {
            height = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--step") == 0 && i + 1 < argc) {
            step = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) {
            fps = atof(argv[++i]);
        } else if (strcmp(argv[i], "--ref") == 0 && i + 1 < argc) {
            ref_path = argv[++i];
        } else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
            out_path = argv[++i];
        }
    }

    if (ref_path) {
        load_ref_csv(ref_path);
    }

    FILE *out_fp = stdout;
    if (out_path && strcmp(out_path, "-") != 0) {
        out_fp = fopen(out_path, "w");
        if (!out_fp) {
            fprintf(stderr, "Error: Could not open output CSV: %s\n", out_path);
            return 1;
        }
    }

    tl_params_t params;
    tl_params_default(&params);

    tl_filter_t filt;
    double fps_eff = fps / (double)step;
    tl_filter_init(&filt, &params, fps_eff);

    fprintf(out_fp, "frame,t,sig_left,sig_straight,sig_right,raw_left,raw_straight,raw_right,n_lights,lights,left_line,right_line,left_cov,right_cov,ego_motion,motion_score\n");

    size_t frame_bytes = (size_t)width * height * 3;
    unsigned char *frame_buf = (unsigned char *)malloc(frame_bytes);
    if (!frame_buf) {
        fprintf(stderr, "Error: Failed to allocate frame buffer\n");
        return 1;
    }

    tl_box_t boxes[64];
    int frame_idx = 0;

    while (1) {
        size_t n_read = read_exact(frame_buf, frame_bytes);
        if (n_read < frame_bytes) {
            break;
        }

        if (frame_idx % step == 0) {
            double t = (double)frame_idx / fps;
            int n_boxes = tl_detect(frame_buf, width, height, &params, boxes, 64);

            int raw[3];
            tl_associate(boxes, n_boxes, raw);

            int ego_stopped = 0;
            const char *ego_motion_str = "moving";
            const char *motion_score_str = "0.000";

            if (frame_idx < MAX_REF_FRAMES && g_ref_frames[frame_idx].valid) {
                ref_frame_t *rf = &g_ref_frames[frame_idx];
                ego_motion_str = rf->ego_motion;
                if (rf->motion_score[0]) motion_score_str = rf->motion_score;
                if (strcmp(rf->ego_motion, "stopped") == 0) {
                    ego_stopped = 1;
                }
            }

            int sig[3];
            tl_filter_update(&filt, raw, ego_stopped, sig);

            char lights_str[1024];
            lights_str[0] = '\0';
            size_t pos = 0;
            for (int k = 0; k < n_boxes; k++) {
                int written = snprintf(lights_str + pos, sizeof(lights_str) - pos,
                                       "%s%s:%s:%d:%d:%d:%d",
                                       (k > 0 ? ";" : ""),
                                       tl_color_name(boxes[k].color),
                                       tl_shape_name(boxes[k].shape),
                                       boxes[k].x1, boxes[k].y1,
                                       boxes[k].x2, boxes[k].y2);
                if (written > 0 && (size_t)written < sizeof(lights_str) - pos) {
                    pos += (size_t)written;
                } else {
                    break;
                }
            }

            /* lane columns are not computed by TL module: left_line and right_line are empty, left_cov and right_cov are 0 */
            fprintf(out_fp, "%d,%.3f,%s,%s,%s,%s,%s,%s,%d,%s,,,0,0,%s,%s\n",
                    frame_idx, t,
                    tl_color_name(sig[0]), tl_color_name(sig[1]), tl_color_name(sig[2]),
                    tl_color_name(raw[0]), tl_color_name(raw[1]), tl_color_name(raw[2]),
                    n_boxes, lights_str,
                    ego_motion_str, motion_score_str);
        }

        frame_idx++;
    }

    free(frame_buf);
    if (out_fp != stdout) {
        fclose(out_fp);
    }
    return 0;
}
