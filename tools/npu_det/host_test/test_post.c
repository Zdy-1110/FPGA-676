#include "../npu_post.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_IMAGES 200
#define MAX_IMAGE_NAME_LEN 128
#define MAX_OUT_DETS 300

typedef struct {
    char name[32];
    int stride;
    int c;
    int h;
    int w;
    float scale;
    int32_t zp;
} tensor_info_t;

static tensor_info_t g_tensors[9] = {
    {"box_s8",  8,  64, 40, 120, 0.1372504234f, -28},
    {"cls_s8",  8,  9,  40, 120, 0.0038208705f, -128},
    {"sum_s8",  8,  1,  40, 120, 0.0039215688f, -128},
    {"box_s16", 16, 64, 20, 60,  0.1147205606f, -9},
    {"cls_s16", 16, 9,  20, 60,  0.0038714506f, -128},
    {"sum_s16", 16, 1,  20, 60,  0.0039215688f, -128},
    {"box_s32", 32, 64, 10, 30,  0.1001869738f, -21},
    {"cls_s32", 32, 9,  10, 30,  0.0038437992f, -128},
    {"sum_s32", 32, 1,  10, 30,  0.0039215688f, -128},
};

static char g_image_names[MAX_IMAGES][MAX_IMAGE_NAME_LEN];
static int g_num_images = 0;

static int load_meta_json(const char *meta_path) {
    FILE *f = fopen(meta_path, "rb");
    if (!f) {
        fprintf(stderr, "Failed to open meta file: %s\n", meta_path);
        return -1;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);

    char *buf = (char *)malloc((size_t)sz + 1);
    if (!buf) {
        fclose(f);
        return -1;
    }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        fclose(f);
        free(buf);
        return -1;
    }
    buf[sz] = '\0';
    fclose(f);

    /* 1. Parse tensor scale and zp */
    for (int k = 0; k < 9; ++k) {
        char key[64];
        snprintf(key, sizeof(key), "\"%s\"", g_tensors[k].name);
        char *p = strstr(buf, key);
        if (p) {
            char *p_scale = strstr(p, "\"scale\":");
            if (p_scale) {
                g_tensors[k].scale = (float)strtod(p_scale + 8, NULL);
            }
            char *p_zp = strstr(p, "\"zp\":");
            if (p_zp) {
                g_tensors[k].zp = (int32_t)strtol(p_zp + 5, NULL, 10);
            }
        }
    }

    /* 2. Parse images array */
    char *p_img = strstr(buf, "\"images\":");
    if (p_img) {
        char *bracket = strchr(p_img, '[');
        char *bracket_end = bracket ? strchr(bracket, ']') : NULL;
        if (bracket && bracket_end) {
            char *cur = bracket + 1;
            while (cur < bracket_end && g_num_images < MAX_IMAGES) {
                char *quote1 = strchr(cur, '\"');
                if (!quote1 || quote1 > bracket_end) break;
                char *quote2 = strchr(quote1 + 1, '\"');
                if (!quote2 || quote2 > bracket_end) break;
                size_t len = (size_t)(quote2 - (quote1 + 1));
                if (len >= MAX_IMAGE_NAME_LEN) len = MAX_IMAGE_NAME_LEN - 1;
                memcpy(g_image_names[g_num_images], quote1 + 1, len);
                g_image_names[g_num_images][len] = '\0';
                g_num_images++;
                cur = quote2 + 1;
            }
        }
    }

    free(buf);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "Usage: %s <data_dir> <fp32|int8> <pr_split|agnostic|class> <output_json>\n", argv[0]);
        return 1;
    }

    const char *data_dir = argv[1];
    const char *type_str = argv[2];
    const char *mode_str = argv[3];
    const char *out_json_path = argv[4];

    bool is_int8 = (strcmp(type_str, "int8") == 0);

    npu_post_config_t cfg;
    npu_post_config_init(&cfg);
    cfg.conf_thres = 0.25f;
    cfg.iou_thres = 0.60f;
    cfg.max_det = 300;

    if (strcmp(mode_str, "pr_split") == 0) {
        cfg.mode = NPU_NMS_PR_SPLIT;
    } else if (strcmp(mode_str, "agnostic") == 0) {
        cfg.mode = NPU_NMS_AGNOSTIC;
    } else if (strcmp(mode_str, "class") == 0) {
        cfg.mode = NPU_NMS_CLASS;
    } else {
        fprintf(stderr, "Unknown NMS mode: %s\n", mode_str);
        return 1;
    }

    char meta_path[512];
    snprintf(meta_path, sizeof(meta_path), "%s/meta.json", data_dir);
    if (load_meta_json(meta_path) != 0) {
        fprintf(stderr, "Failed to load %s\n", meta_path);
        return 1;
    }

    printf("Loaded meta: %d images. Running %s path, NMS mode=%s\n",
           g_num_images, is_int8 ? "INT8" : "FP32", mode_str);

    /* Allocate buffers for 9 tensors */
    void *raw_bufs[9];
    for (int k = 0; k < 9; ++k) {
        size_t num_elems = (size_t)g_tensors[k].c * (size_t)g_tensors[k].h * (size_t)g_tensors[k].w;
        size_t elem_size = is_int8 ? sizeof(int8_t) : sizeof(float);
        raw_bufs[k] = malloc(num_elems * elem_size);
        if (!raw_bufs[k]) {
            fprintf(stderr, "Memory allocation failed for tensor %d\n", k);
            return 1;
        }
    }

    FILE *fout = fopen(out_json_path, "w");
    if (!fout) {
        fprintf(stderr, "Failed to open output json: %s\n", out_json_path);
        return 1;
    }

    fprintf(fout, "[\n");
    bool first_record = true;
    int total_dets = 0;

    for (int img_idx = 0; img_idx < g_num_images; ++img_idx) {
        npu_tensor_t tensors[9];
        for (int k = 0; k < 9; ++k) {
            char bin_path[512];
            if (is_int8) {
                snprintf(bin_path, sizeof(bin_path), "%s/rknn_int8_%03d_%d.bin", data_dir, img_idx, k);
            } else {
                snprintf(bin_path, sizeof(bin_path), "%s/onnx_fp32_%03d_%d.bin", data_dir, img_idx, k);
            }

            FILE *fb = fopen(bin_path, "rb");
            if (!fb) {
                fprintf(stderr, "Missing bin file: %s\n", bin_path);
                fclose(fout);
                return 1;
            }
            size_t num_elems = (size_t)g_tensors[k].c * (size_t)g_tensors[k].h * (size_t)g_tensors[k].w;
            size_t elem_size = is_int8 ? sizeof(int8_t) : sizeof(float);
            size_t nread = fread(raw_bufs[k], elem_size, num_elems, fb);
            fclose(fb);
            if (nread != num_elems) {
                fprintf(stderr, "Truncated read in %s\n", bin_path);
                fclose(fout);
                return 1;
            }

            tensors[k].data = raw_bufs[k];
            tensors[k].scale = g_tensors[k].scale;
            tensors[k].zp = g_tensors[k].zp;
            tensors[k].channel_stride = g_tensors[k].h * g_tensors[k].w;
            tensors[k].row_stride = g_tensors[k].w;
            tensors[k].col_stride = 1;
        }

        npu_det_t out_dets[MAX_OUT_DETS];
        int num_dets = 0;
        if (is_int8) {
            num_dets = npu_post_process_9tensors_int8(&cfg, tensors, out_dets, MAX_OUT_DETS);
        } else {
            num_dets = npu_post_process_9tensors_fp32(&cfg, tensors, out_dets, MAX_OUT_DETS);
        }

        total_dets += num_dets;

        for (int d = 0; d < num_dets; ++d) {
            if (!first_record) {
                fprintf(fout, ",\n");
            }
            first_record = false;

            fprintf(fout, "  {\n");
            fprintf(fout, "    \"img_idx\": %d,\n", img_idx);
            fprintf(fout, "    \"image\": \"%s\",\n", g_image_names[img_idx]);
            fprintf(fout, "    \"cls\": %d,\n", out_dets[d].cls);
            fprintf(fout, "    \"score\": %.6f,\n", out_dets[d].score);
            fprintf(fout, "    \"box\": [%.5f, %.5f, %.5f, %.5f]\n",
                    out_dets[d].x0, out_dets[d].y0, out_dets[d].x1, out_dets[d].y1);
            fprintf(fout, "  }");
        }
    }

    fprintf(fout, "\n]\n");
    fclose(fout);

    for (int k = 0; k < 9; ++k) {
        free(raw_bufs[k]);
    }

    printf("Done. Processed %d images, total detections: %d -> %s\n",
           g_num_images, total_dets, out_json_path);
    return 0;
}
