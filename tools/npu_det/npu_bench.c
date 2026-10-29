#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <dirent.h>
#include <math.h>
#include <sys/types.h>
#include <inttypes.h>

#include "rknn_api.h"
#include "npu_post.h"

#define WARMUP_ITERS 10
#define DEFAULT_BENCH_ITERS 100
#define EXPECTED_INPUT_SIZE 921600  /* 960 * 320 * 3 */
#define MAX_DETS 300

static const char *k_canonical_output_names[9] = {
    "box_s8", "cls_s8", "sum_s8",
    "box_s16", "cls_s16", "sum_s16",
    "box_s32", "cls_s32", "sum_s32"
};

static inline double get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static const char *get_basename(const char *path) {
    if (!path) return "bench_input";
    const char *p1 = strrchr(path, '/');
    const char *p2 = strrchr(path, '\\');
    const char *p = (p1 > p2) ? p1 : p2;
    return p ? (p + 1) : path;
}

static void print_npu_freq(void) {
    DIR *dir = opendir("/sys/class/devfreq");
    if (!dir) {
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strstr(entry->d_name, "npu") != NULL) {
            char path[512];
            snprintf(path, sizeof(path), "/sys/class/devfreq/%s/cur_freq", entry->d_name);
            FILE *f = fopen(path, "r");
            if (f) {
                unsigned long freq = 0;
                if (fscanf(f, "%lu", &freq) == 1) {
                    char gov[64] = "unknown";
                    char gov_path[512];
                    snprintf(gov_path, sizeof(gov_path), "/sys/class/devfreq/%s/governor", entry->d_name);
                    FILE *fg = fopen(gov_path, "r");
                    if (fg) {
                        if (fscanf(fg, "%63s", gov) != 1) {
                            strncpy(gov, "unknown", sizeof(gov) - 1);
                        }
                        fclose(fg);
                    }
                    printf("NPU devfreq (%s): %lu Hz (%.1f MHz), governor: %s\n",
                           entry->d_name, freq, (double)freq / 1e6, gov);
                }
                fclose(f);
            }
        }
    }
    closedir(dir);
}

static int find_output_index(const rknn_tensor_attr *attrs, uint32_t n_attrs, const char *name, int default_idx) {
    for (uint32_t i = 0; i < n_attrs; i++) {
        if (strcmp(attrs[i].name, name) == 0) {
            return (int)i;
        }
    }
    for (uint32_t i = 0; i < n_attrs; i++) {
        if (strstr(attrs[i].name, name) != NULL) {
            return (int)i;
        }
    }
    if (default_idx >= 0 && default_idx < (int)n_attrs) {
        return default_idx;
    }
    return -1;
}

static void print_usage(const char *prog) {
    fprintf(stderr, "Usage: %s <model.rknn> [input_960x320.rgb] [iters=100] [--zero-copy] [--perf] [--perf-out <path>] [--json <path>]\n", prog);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  --zero-copy         Use rknn_create_mem / rknn_set_io_mem zero-copy API\n");
    fprintf(stderr, "  --perf              Enable RKNN performance profiling\n");
    fprintf(stderr, "  --perf-out <path>   Write detailed performance report to file (also logs to stdout)\n");
    fprintf(stderr, "  --json <path>       Export detections to JSON file (host_test compatible)\n");
    fprintf(stderr, "  --iters <N>         Number of benchmark iterations (default: 100)\n");
    fprintf(stderr, "  -h, --help          Show this help message\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }

    const char *model_path = NULL;
    const char *input_path = NULL;
    const char *json_path = NULL;
    const char *perf_out_path = NULL;
    int iters = DEFAULT_BENCH_ITERS;
    bool zero_copy = false;
    bool enable_perf = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--zero-copy") == 0) {
            zero_copy = true;
        } else if (strcmp(argv[i], "--perf") == 0) {
            enable_perf = true;
        } else if (strcmp(argv[i], "--perf-out") == 0) {
            if (i + 1 < argc) {
                perf_out_path = argv[++i];
                enable_perf = true;
            } else {
                fprintf(stderr, "Error: --perf-out requires a file path\n");
                return 1;
            }
        } else if (strcmp(argv[i], "--json") == 0) {
            if (i + 1 < argc) {
                json_path = argv[++i];
            } else {
                fprintf(stderr, "Error: --json requires a file path\n");
                return 1;
            }
        } else if (strcmp(argv[i], "--iters") == 0) {
            if (i + 1 < argc) {
                iters = atoi(argv[++i]);
            } else {
                fprintf(stderr, "Error: --iters requires an integer\n");
                return 1;
            }
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "Error: unknown option '%s'\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        } else {
            if (!model_path) {
                model_path = argv[i];
            } else if (!input_path && !isdigit((unsigned char)argv[i][0])) {
                input_path = argv[i];
            } else {
                int val = atoi(argv[i]);
                if (val > 0) {
                    iters = val;
                } else if (!input_path) {
                    input_path = argv[i];
                }
            }
        }
    }

    if (!model_path) {
        fprintf(stderr, "Error: model path is required\n");
        print_usage(argv[0]);
        return 1;
    }
    if (iters <= 0) {
        iters = DEFAULT_BENCH_ITERS;
    }

    printf("==================== NPU Benchmark ====================\n");
    printf("Model:       %s\n", model_path);
    printf("Input:       %s\n", input_path ? input_path : "(none, using zeros)");
    printf("Mode:        %s\n", zero_copy ? "Zero-Copy" : "Normal (inputs_set / outputs_get)");
    printf("Iterations:  %d (warmup: %d)\n", iters, WARMUP_ITERS);
    printf("Perf Collect:%s\n", enable_perf ? " Enabled" : " Disabled");
    if (perf_out_path) {
        printf("Perf Output: %s\n", perf_out_path);
    }
    if (json_path) {
        printf("JSON output: %s\n", json_path);
    }
    printf("-------------------------------------------------------\n");

    /* 1. Read model and rknn_init */
    FILE *fp_model = fopen(model_path, "rb");
    if (!fp_model) {
        fprintf(stderr, "Error: failed to open model file '%s'\n", model_path);
        return 1;
    }
    if (fseek(fp_model, 0, SEEK_END) != 0) {
        fprintf(stderr, "Error: fseek failed on model file\n");
        fclose(fp_model);
        return 1;
    }
    long model_size = ftell(fp_model);
    if (fseek(fp_model, 0, SEEK_SET) != 0 || model_size <= 0) {
        fprintf(stderr, "Error: invalid model size (%ld bytes)\n", model_size);
        fclose(fp_model);
        return 1;
    }

    void *model_data = malloc((size_t)model_size);
    if (!model_data) {
        fprintf(stderr, "Error: failed to allocate %ld bytes for model buffer\n", model_size);
        fclose(fp_model);
        return 1;
    }
    if (fread(model_data, 1, (size_t)model_size, fp_model) != (size_t)model_size) {
        fprintf(stderr, "Error: failed to read model data\n");
        free(model_data);
        fclose(fp_model);
        return 1;
    }
    fclose(fp_model);

    rknn_context ctx = 0;
    uint32_t init_flags = enable_perf ? RKNN_FLAG_COLLECT_PERF_MASK : 0;
    int ret = rknn_init(&ctx, model_data, (uint32_t)model_size, init_flags, NULL);
    free(model_data);
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "Error: rknn_init failed with code %d\n", ret);
        return 1;
    }

    /* 2. Query SDK and driver version */
    rknn_sdk_version sdk_ver;
    memset(&sdk_ver, 0, sizeof(sdk_ver));
    ret = rknn_query(ctx, RKNN_QUERY_SDK_VERSION, &sdk_ver, sizeof(sdk_ver));
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "Error: rknn_query(RKNN_QUERY_SDK_VERSION) failed: %d\n", ret);
        rknn_destroy(ctx);
        return 1;
    }
    printf("SDK version:    %s\n", sdk_ver.api_version);
    printf("Driver version: %s\n", sdk_ver.drv_version);

    /* 3. Query devfreq cur_freq */
    print_npu_freq();

    /* 4. Query input / output tensor count */
    rknn_input_output_num io_num;
    memset(&io_num, 0, sizeof(io_num));
    ret = rknn_query(ctx, RKNN_QUERY_IN_OUT_NUM, &io_num, sizeof(io_num));
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "Error: rknn_query(RKNN_QUERY_IN_OUT_NUM) failed: %d\n", ret);
        rknn_destroy(ctx);
        return 1;
    }
    printf("Model I/O:      %u inputs, %u outputs\n", io_num.n_input, io_num.n_output);

    /* 5. Query and print input attributes */
    rknn_tensor_attr *input_attrs = (rknn_tensor_attr *)calloc(io_num.n_input, sizeof(rknn_tensor_attr));
    if (!input_attrs) {
        fprintf(stderr, "Error: failed to allocate memory for input_attrs\n");
        rknn_destroy(ctx);
        return 1;
    }
    for (uint32_t i = 0; i < io_num.n_input; i++) {
        input_attrs[i].index = i;
        ret = rknn_query(ctx, RKNN_QUERY_INPUT_ATTR, &input_attrs[i], sizeof(rknn_tensor_attr));
        if (ret != RKNN_SUCC) {
            fprintf(stderr, "Error: rknn_query(RKNN_QUERY_INPUT_ATTR) index %u failed: %d\n", i, ret);
            free(input_attrs);
            rknn_destroy(ctx);
            return 1;
        }

        char dims_buf[128] = "[";
        for (uint32_t d = 0; d < input_attrs[i].n_dims; d++) {
            char tmp[16];
            snprintf(tmp, sizeof(tmp), "%s%u", (d > 0 ? ", " : ""), input_attrs[i].dims[d]);
            strncat(dims_buf, tmp, sizeof(dims_buf) - strlen(dims_buf) - 1);
        }
        strncat(dims_buf, "]", sizeof(dims_buf) - strlen(dims_buf) - 1);

        printf("  Input  %u: name='%s', dims=%s, fmt=%s, type=%s, qnt_type=%s, zp=%d, scale=%.6f, size=%u\n",
               i, input_attrs[i].name, dims_buf,
               get_format_string(input_attrs[i].fmt),
               get_type_string(input_attrs[i].type),
               get_qnt_type_string(input_attrs[i].qnt_type),
               input_attrs[i].zp, input_attrs[i].scale, input_attrs[i].size);
    }

    /* 6. Query and print output attributes */
    rknn_tensor_attr *output_attrs = (rknn_tensor_attr *)calloc(io_num.n_output, sizeof(rknn_tensor_attr));
    if (!output_attrs) {
        fprintf(stderr, "Error: failed to allocate memory for output_attrs\n");
        free(input_attrs);
        rknn_destroy(ctx);
        return 1;
    }
    for (uint32_t i = 0; i < io_num.n_output; i++) {
        output_attrs[i].index = i;
        ret = rknn_query(ctx, RKNN_QUERY_OUTPUT_ATTR, &output_attrs[i], sizeof(rknn_tensor_attr));
        if (ret != RKNN_SUCC) {
            fprintf(stderr, "Error: rknn_query(RKNN_QUERY_OUTPUT_ATTR) index %u failed: %d\n", i, ret);
            free(output_attrs);
            free(input_attrs);
            rknn_destroy(ctx);
            return 1;
        }

        char dims_buf[128] = "[";
        for (uint32_t d = 0; d < output_attrs[i].n_dims; d++) {
            char tmp[16];
            snprintf(tmp, sizeof(tmp), "%s%u", (d > 0 ? ", " : ""), output_attrs[i].dims[d]);
            strncat(dims_buf, tmp, sizeof(dims_buf) - strlen(dims_buf) - 1);
        }
        strncat(dims_buf, "]", sizeof(dims_buf) - strlen(dims_buf) - 1);

        printf("  Output %u: name='%s', dims=%s, fmt=%s, type=%s, qnt_type=%s, zp=%d, scale=%.6f, size=%u\n",
               i, output_attrs[i].name, dims_buf,
               get_format_string(output_attrs[i].fmt),
               get_type_string(output_attrs[i].type),
               get_qnt_type_string(output_attrs[i].qnt_type),
               output_attrs[i].zp, output_attrs[i].scale, output_attrs[i].size);
    }

    /* 7. Load input data */
    uint32_t req_input_size = input_attrs[0].size > 0 ? input_attrs[0].size : EXPECTED_INPUT_SIZE;
    void *input_buf = calloc(1, req_input_size);
    if (!input_buf) {
        fprintf(stderr, "Error: failed to allocate %u bytes for input buffer\n", req_input_size);
        free(output_attrs);
        free(input_attrs);
        rknn_destroy(ctx);
        return 1;
    }

    if (input_path) {
        FILE *fi = fopen(input_path, "rb");
        if (!fi) {
            fprintf(stderr, "Error: failed to open input file '%s'\n", input_path);
            free(input_buf);
            free(output_attrs);
            free(input_attrs);
            rknn_destroy(ctx);
            return 1;
        }
        fseek(fi, 0, SEEK_END);
        long fi_sz = ftell(fi);
        fseek(fi, 0, SEEK_SET);
        if (fi_sz != (long)req_input_size) {
            fprintf(stderr, "Error: input file '%s' size %ld != expected %u bytes\n",
                    input_path, fi_sz, req_input_size);
            fclose(fi);
            free(input_buf);
            free(output_attrs);
            free(input_attrs);
            rknn_destroy(ctx);
            return 1;
        }
        size_t to_read = (size_t)(fi_sz < (long)req_input_size ? fi_sz : (long)req_input_size);
        size_t nread = fread(input_buf, 1, to_read, fi);
        fclose(fi);
        if (nread != to_read) {
            fprintf(stderr, "Error: short read on input file '%s'\n", input_path);
            free(input_buf);
            free(output_attrs);
            free(input_attrs);
            rknn_destroy(ctx);
            return 1;
        }
        printf("Loaded %zu bytes from '%s'\n", nread, input_path);
    }

    /* 8. Execute Benchmark */
    int exit_code = 0;
    rknn_output *normal_outputs = NULL;
    rknn_tensor_mem **zc_input_mems = NULL;
    rknn_tensor_mem **zc_output_mems = NULL;

    if (zero_copy) {
        /* Zero-Copy Mode */
        zc_input_mems = (rknn_tensor_mem **)calloc(io_num.n_input, sizeof(rknn_tensor_mem *));
        zc_output_mems = (rknn_tensor_mem **)calloc(io_num.n_output, sizeof(rknn_tensor_mem *));
        if (!zc_input_mems || !zc_output_mems) {
            fprintf(stderr, "Error: failed to allocate memory for zero-copy memory pointers\n");
            exit_code = 1;
            goto cleanup;
        }

        for (uint32_t i = 0; i < io_num.n_input; i++) {
            uint32_t mem_sz = input_attrs[i].size_with_stride > input_attrs[i].size ?
                              input_attrs[i].size_with_stride : input_attrs[i].size;
            zc_input_mems[i] = rknn_create_mem(ctx, mem_sz);
            if (!zc_input_mems[i]) {
                fprintf(stderr, "Error: rknn_create_mem failed for input %u (size %u)\n", i, mem_sz);
                exit_code = 1;
                goto cleanup;
            }
            if (i == 0 && input_buf) {
                uint32_t copy_sz = req_input_size < mem_sz ? req_input_size : mem_sz;
                memcpy(zc_input_mems[i]->virt_addr, input_buf, copy_sz);
            }
            rknn_tensor_attr in_attr = input_attrs[i];
            in_attr.type = RKNN_TENSOR_UINT8;
            in_attr.fmt = RKNN_TENSOR_NHWC;
            in_attr.pass_through = 0;
            ret = rknn_set_io_mem(ctx, zc_input_mems[i], &in_attr);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_set_io_mem failed for input %u: %d\n", i, ret);
                exit_code = 1;
                goto cleanup;
            }
        }

        for (uint32_t i = 0; i < io_num.n_output; i++) {
            uint32_t mem_sz = output_attrs[i].size_with_stride > output_attrs[i].size ?
                              output_attrs[i].size_with_stride : output_attrs[i].size;
            zc_output_mems[i] = rknn_create_mem(ctx, mem_sz);
            if (!zc_output_mems[i]) {
                fprintf(stderr, "Error: rknn_create_mem failed for output %u (size %u)\n", i, mem_sz);
                exit_code = 1;
                goto cleanup;
            }
            ret = rknn_set_io_mem(ctx, zc_output_mems[i], &output_attrs[i]);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_set_io_mem failed for output %u: %d\n", i, ret);
                exit_code = 1;
                goto cleanup;
            }
        }

        /* Warmup */
        printf("Running %d warmup iterations...\n", WARMUP_ITERS);
        for (int w = 0; w < WARMUP_ITERS; w++) {
            ret = rknn_run(ctx, NULL);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_run failed during warmup iteration %d: %d\n", w, ret);
                exit_code = 1;
                goto cleanup;
            }
        }

        /* Timed benchmark */
        printf("Benchmarking %d iterations (Zero-Copy)...\n", iters);
        double t_run_sum = 0.0, t_run_min = 1e9, t_run_max = 0.0;
        for (int it = 0; it < iters; it++) {
            double t0 = get_time_ms();
            ret = rknn_run(ctx, NULL);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_run failed during benchmark iteration %d: %d\n", it, ret);
                exit_code = 1;
                goto cleanup;
            }
            double t1 = get_time_ms();
            double dt = t1 - t0;
            t_run_sum += dt;
            if (dt < t_run_min) t_run_min = dt;
            if (dt > t_run_max) t_run_max = dt;
        }

        double t_run_avg = t_run_sum / (double)iters;
        printf("-------------------------------------------------------\n");
        printf("Zero-Copy Benchmark Results (%d iterations):\n", iters);
        printf("  run:         avg = %8.3f ms, min = %8.3f ms, max = %8.3f ms\n",
               t_run_avg, t_run_min, t_run_max);
        printf("  FPS:         %8.2f fps\n", 1000.0 / t_run_avg);
        printf("-------------------------------------------------------\n");

    } else {
        /* Normal Mode */
        normal_outputs = (rknn_output *)calloc(io_num.n_output, sizeof(rknn_output));
        if (!normal_outputs) {
            fprintf(stderr, "Error: failed to allocate memory for normal_outputs\n");
            exit_code = 1;
            goto cleanup;
        }
        for (uint32_t i = 0; i < io_num.n_output; i++) {
            normal_outputs[i].want_float = 0;
            normal_outputs[i].is_prealloc = 0;
            normal_outputs[i].index = i;
        }

        rknn_input input;
        memset(&input, 0, sizeof(input));
        input.index = 0;
        input.type = RKNN_TENSOR_UINT8;
        input.size = req_input_size;
        input.fmt = RKNN_TENSOR_NHWC;
        input.buf = input_buf;
        input.pass_through = 0;

        /* Warmup */
        printf("Running %d warmup iterations...\n", WARMUP_ITERS);
        for (int w = 0; w < WARMUP_ITERS; w++) {
            ret = rknn_inputs_set(ctx, io_num.n_input, &input);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_inputs_set failed during warmup %d: %d\n", w, ret);
                exit_code = 1;
                goto cleanup;
            }
            ret = rknn_run(ctx, NULL);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_run failed during warmup %d: %d\n", w, ret);
                exit_code = 1;
                goto cleanup;
            }
            ret = rknn_outputs_get(ctx, io_num.n_output, normal_outputs, NULL);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_outputs_get failed during warmup %d: %d\n", w, ret);
                exit_code = 1;
                goto cleanup;
            }
            ret = rknn_outputs_release(ctx, io_num.n_output, normal_outputs);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_outputs_release failed during warmup %d: %d\n", w, ret);
                exit_code = 1;
                goto cleanup;
            }
        }

        /* Timed benchmark */
        printf("Benchmarking %d iterations (Normal Mode)...\n", iters);
        double t_set_sum = 0.0, t_set_min = 1e9, t_set_max = 0.0;
        double t_run_sum = 0.0, t_run_min = 1e9, t_run_max = 0.0;
        double t_get_sum = 0.0, t_get_min = 1e9, t_get_max = 0.0;
        double t_tot_sum = 0.0, t_tot_min = 1e9, t_tot_max = 0.0;

        for (int it = 0; it < iters; it++) {
            double t0 = get_time_ms();
            ret = rknn_inputs_set(ctx, io_num.n_input, &input);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_inputs_set failed at iteration %d: %d\n", it, ret);
                exit_code = 1;
                goto cleanup;
            }
            double t1 = get_time_ms();

            ret = rknn_run(ctx, NULL);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_run failed at iteration %d: %d\n", it, ret);
                exit_code = 1;
                goto cleanup;
            }
            double t2 = get_time_ms();

            ret = rknn_outputs_get(ctx, io_num.n_output, normal_outputs, NULL);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_outputs_get failed at iteration %d: %d\n", it, ret);
                exit_code = 1;
                goto cleanup;
            }
            double t3 = get_time_ms();

            double dt_set = t1 - t0;
            double dt_run = t2 - t1;
            double dt_get = t3 - t2;
            double dt_tot = t3 - t0;

            t_set_sum += dt_set; if (dt_set < t_set_min) t_set_min = dt_set; if (dt_set > t_set_max) t_set_max = dt_set;
            t_run_sum += dt_run; if (dt_run < t_run_min) t_run_min = dt_run; if (dt_run > t_run_max) t_run_max = dt_run;
            t_get_sum += dt_get; if (dt_get < t_get_min) t_get_min = dt_get; if (dt_get > t_get_max) t_get_max = dt_get;
            t_tot_sum += dt_tot; if (dt_tot < t_tot_min) t_tot_min = dt_tot; if (dt_tot > t_tot_max) t_tot_max = dt_tot;

            /* Retain outputs of the final iteration if post-processing or perf query is needed */
            if (it == iters - 1 && (input_path != NULL || enable_perf)) {
                break;
            }

            ret = rknn_outputs_release(ctx, io_num.n_output, normal_outputs);
            if (ret != RKNN_SUCC) {
                fprintf(stderr, "Error: rknn_outputs_release failed at iteration %d: %d\n", it, ret);
                exit_code = 1;
                goto cleanup;
            }
        }

        double t_set_avg = t_set_sum / (double)iters;
        double t_run_avg = t_run_sum / (double)iters;
        double t_get_avg = t_get_sum / (double)iters;
        double t_tot_avg = t_tot_sum / (double)iters;

        printf("-------------------------------------------------------\n");
        printf("Normal Mode Benchmark Results (%d iterations):\n", iters);
        printf("  inputs_set:  avg = %8.3f ms, min = %8.3f ms, max = %8.3f ms\n",
               t_set_avg, t_set_min, t_set_max);
        printf("  run:         avg = %8.3f ms, min = %8.3f ms, max = %8.3f ms\n",
               t_run_avg, t_run_min, t_run_max);
        printf("  outputs_get: avg = %8.3f ms, min = %8.3f ms, max = %8.3f ms\n",
               t_get_avg, t_get_min, t_get_max);
        printf("  Total:       avg = %8.3f ms, min = %8.3f ms, max = %8.3f ms\n",
               t_tot_avg, t_tot_min, t_tot_max);
        printf("  FPS (Total): %8.2f fps\n", 1000.0 / t_tot_avg);
        printf("-------------------------------------------------------\n");
    }

    /* Print frequency and governor again after benchmark loop */
    print_npu_freq();

    /* Performance profiling query if enabled */
    if (enable_perf) {
        rknn_perf_run perf_run;
        memset(&perf_run, 0, sizeof(perf_run));
        ret = rknn_query(ctx, RKNN_QUERY_PERF_RUN, &perf_run, sizeof(perf_run));
        if (ret == RKNN_SUCC) {
            printf("RKNN Perf Run: %" PRId64 " us (%.3f ms)\n",
                   perf_run.run_duration, (double)perf_run.run_duration / 1000.0);
        } else {
            fprintf(stderr, "Warning: rknn_query(RKNN_QUERY_PERF_RUN) failed: %d\n", ret);
        }

        rknn_perf_detail perf_detail;
        memset(&perf_detail, 0, sizeof(perf_detail));
        ret = rknn_query(ctx, RKNN_QUERY_PERF_DETAIL, &perf_detail, sizeof(perf_detail));
        if (ret == RKNN_SUCC) {
            printf("---------------- RKNN Perf Detail ---------------------\n");
            if (perf_detail.perf_data && perf_detail.data_len > 0) {
                printf("%.*s\n", (int)perf_detail.data_len, perf_detail.perf_data);
                if (perf_out_path) {
                    FILE *fp_perf = fopen(perf_out_path, "w");
                    if (fp_perf) {
                        fwrite(perf_detail.perf_data, 1, (size_t)perf_detail.data_len, fp_perf);
                        fclose(fp_perf);
                        printf("Saved perf detail to '%s'\n", perf_out_path);
                    } else {
                        fprintf(stderr, "Warning: failed to open perf output file '%s'\n", perf_out_path);
                    }
                }
            } else if (perf_detail.perf_data) {
                printf("%s\n", perf_detail.perf_data);
                if (perf_out_path) {
                    FILE *fp_perf = fopen(perf_out_path, "w");
                    if (fp_perf) {
                        fputs(perf_detail.perf_data, fp_perf);
                        fclose(fp_perf);
                        printf("Saved perf detail to '%s'\n", perf_out_path);
                    } else {
                        fprintf(stderr, "Warning: failed to open perf output file '%s'\n", perf_out_path);
                    }
                }
            } else {
                printf("(empty perf detail)\n");
            }
            printf("-------------------------------------------------------\n");
        } else {
            fprintf(stderr, "Warning: rknn_query(RKNN_QUERY_PERF_DETAIL) failed: %d\n", ret);
        }
    }

    /* 9. Post-processing if input file was provided */
    if (input_path != NULL) {
        if (io_num.n_output != 9) {
            fprintf(stderr, "Error: expected 9 outputs for post-processing, model has %u\n", io_num.n_output);
            exit_code = 1;
            goto release_outputs;
        }

        npu_tensor_t post_tensors[9];
        memset(post_tensors, 0, sizeof(post_tensors));

        for (int k = 0; k < 9; k++) {
            int out_idx = find_output_index(output_attrs, io_num.n_output, k_canonical_output_names[k], k);
            if (out_idx < 0) {
                fprintf(stderr, "Error: could not find output tensor for '%s'\n", k_canonical_output_names[k]);
                exit_code = 1;
                goto release_outputs;
            }

            const rknn_tensor_attr *attr = &output_attrs[out_idx];
            const void *buf_ptr = zero_copy ? zc_output_mems[out_idx]->virt_addr : normal_outputs[out_idx].buf;
            if (!buf_ptr) {
                fprintf(stderr, "Error: NULL buffer pointer for tensor %s (idx %d)\n", attr->name, out_idx);
                exit_code = 1;
                goto release_outputs;
            }

            post_tensors[k].data = buf_ptr;
            post_tensors[k].scale = attr->scale;
            post_tensors[k].zp = attr->zp;

            if (attr->fmt == RKNN_TENSOR_NCHW) {
                if (attr->n_dims != 4) {
                    fprintf(stderr, "Error: tensor %s has NCHW format but n_dims=%u != 4\n",
                            attr->name, attr->n_dims);
                    exit_code = 1;
                    goto release_outputs;
                }
                uint32_t h = attr->dims[2];
                uint32_t w = attr->dims[3];
                post_tensors[k].n_channels = (int32_t)attr->dims[1];
                post_tensors[k].channel_stride = (int32_t)(h * w);
                post_tensors[k].row_stride = (int32_t)w;
                post_tensors[k].col_stride = 1;
            } else if (attr->fmt == RKNN_TENSOR_NHWC) {
                if (attr->n_dims != 4) {
                    fprintf(stderr, "Error: tensor %s has NHWC format but n_dims=%u != 4\n",
                            attr->name, attr->n_dims);
                    exit_code = 1;
                    goto release_outputs;
                }
                uint32_t w = attr->dims[2];
                uint32_t c = attr->dims[3];
                post_tensors[k].n_channels = (int32_t)attr->dims[3];
                post_tensors[k].row_stride = (int32_t)(w * c);
                post_tensors[k].col_stride = (int32_t)c;
                post_tensors[k].channel_stride = 1;
            } else {
                fprintf(stderr, "Error: unsupported tensor format %d for %s (only NCHW and NHWC supported)\n",
                        attr->fmt, attr->name);
                exit_code = 1;
                goto release_outputs;
            }
        }

        npu_post_config_t cfg;
        npu_post_config_init(&cfg);
        cfg.conf_thres = NPU_DEFAULT_CONF_THRES; /* 0.25f */
        cfg.iou_thres = NPU_DEFAULT_IOU_THRES;   /* 0.60f */
        cfg.max_cand = NPU_DEFAULT_MAX_CAND;     /* 1000 */
        cfg.max_det = MAX_DETS;                  /* 300 */
        cfg.mode = NPU_NMS_PR_SPLIT;             /* pr_split */

        npu_det_t dets[MAX_DETS];
        double t_post0 = get_time_ms();
        int num_dets = npu_post_process_9tensors_int8(&cfg, post_tensors, dets, MAX_DETS);
        double t_post1 = get_time_ms();

        printf("Post-processing (INT8, pr_split, conf=0.25, iou=0.6, max_det=300):\n");
        printf("  Detections: %d boxes (decoded in %.3f ms)\n", num_dets, t_post1 - t_post0);
        for (int d = 0; d < num_dets; d++) {
            float sx0, sy0, sx1, sy1;
            npu_map_to_src(dets[d].x0, dets[d].y0, dets[d].x1, dets[d].y1,
                           &sx0, &sy0, &sx1, &sy1);
            printf("  [%2d] cls=%d score=%.4f band=[%.1f, %.1f, %.1f, %.1f] src=[%.1f, %.1f, %.1f, %.1f]\n",
                   d, dets[d].cls, dets[d].score,
                   dets[d].x0, dets[d].y0, dets[d].x1, dets[d].y1,
                   sx0, sy0, sx1, sy1);
        }

        if (json_path) {
            FILE *fj = fopen(json_path, "w");
            if (!fj) {
                fprintf(stderr, "Error: failed to open json output file '%s'\n", json_path);
                exit_code = 1;
            } else {
                const char *img_name = get_basename(input_path);
                fprintf(fj, "[\n");
                for (int d = 0; d < num_dets; d++) {
                    fprintf(fj, "  {\n");
                    fprintf(fj, "    \"img_idx\": 0,\n");
                    fprintf(fj, "    \"image\": \"%s\",\n", img_name);
                    fprintf(fj, "    \"cls\": %d,\n", dets[d].cls);
                    fprintf(fj, "    \"score\": %.6f,\n", dets[d].score);
                    fprintf(fj, "    \"box\": [%.5f, %.5f, %.5f, %.5f]\n",
                            dets[d].x0, dets[d].y0, dets[d].x1, dets[d].y1);
                    fprintf(fj, "  }%s\n", (d + 1 < num_dets) ? "," : "");
                }
                fprintf(fj, "]\n");
                fclose(fj);
                printf("Saved %d detections to '%s'\n", num_dets, json_path);
            }
        }
    }

release_outputs:
    if (!zero_copy && normal_outputs && (input_path != NULL || enable_perf)) {
        rknn_outputs_release(ctx, io_num.n_output, normal_outputs);
    }

cleanup:
    if (zc_input_mems) {
        for (uint32_t i = 0; i < io_num.n_input; i++) {
            if (zc_input_mems[i]) {
                rknn_destroy_mem(ctx, zc_input_mems[i]);
            }
        }
        free(zc_input_mems);
    }
    if (zc_output_mems) {
        for (uint32_t i = 0; i < io_num.n_output; i++) {
            if (zc_output_mems[i]) {
                rknn_destroy_mem(ctx, zc_output_mems[i]);
            }
        }
        free(zc_output_mems);
    }
    if (normal_outputs) {
        free(normal_outputs);
    }
    if (input_buf) {
        free(input_buf);
    }
    if (output_attrs) {
        free(output_attrs);
    }
    if (input_attrs) {
        free(input_attrs);
    }
    if (ctx != 0) {
        rknn_destroy(ctx);
    }

    return exit_code;
}
