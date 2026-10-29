#include "tl_det.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

static const int hdiv_table[256] = {
         0, 174763,  87381,  58254,  43691,  34953,  29127,  24966,  21845,  19418,  17476,  15888,  14564,  13443,  12483,  11651,
     10923,  10280,   9709,   9198,   8738,   8322,   7944,   7598,   7282,   6991,   6722,   6473,   6242,   6026,   5825,   5638,
      5461,   5296,   5140,   4993,   4855,   4723,   4599,   4481,   4369,   4263,   4161,   4064,   3972,   3884,   3799,   3718,
      3641,   3567,   3495,   3427,   3361,   3297,   3236,   3178,   3121,   3066,   3013,   2962,   2913,   2865,   2819,   2774,
      2731,   2689,   2648,   2608,   2570,   2533,   2497,   2461,   2427,   2394,   2362,   2330,   2300,   2270,   2241,   2212,
      2185,   2158,   2131,   2106,   2081,   2056,   2032,   2009,   1986,   1964,   1942,   1920,   1900,   1879,   1859,   1840,
      1820,   1802,   1783,   1765,   1748,   1730,   1713,   1697,   1680,   1664,   1649,   1633,   1618,   1603,   1589,   1574,
      1560,   1547,   1533,   1520,   1507,   1494,   1481,   1469,   1456,   1444,   1432,   1421,   1409,   1398,   1387,   1376,
      1365,   1355,   1344,   1334,   1324,   1314,   1304,   1295,   1285,   1276,   1266,   1257,   1248,   1239,   1231,   1222,
      1214,   1205,   1197,   1189,   1181,   1173,   1165,   1157,   1150,   1142,   1135,   1128,   1120,   1113,   1106,   1099,
      1092,   1085,   1079,   1072,   1066,   1059,   1053,   1046,   1040,   1034,   1028,   1022,   1016,   1010,   1004,    999,
       993,    987,    982,    976,    971,    966,    960,    955,    950,    945,    940,    935,    930,    925,    920,    915,
       910,    906,    901,    896,    892,    887,    883,    878,    874,    869,    865,    861,    857,    853,    848,    844,
       840,    836,    832,    828,    824,    820,    817,    813,    809,    805,    802,    798,    794,    791,    787,    784,
       780,    777,    773,    770,    767,    763,    760,    757,    753,    750,    747,    744,    741,    737,    734,    731,
       728,    725,    722,    719,    716,    713,    710,    708,    705,    702,    699,    696,    694,    691,    688,    685
};

static const int sdiv_table[256] = {
         0, 1044480, 522240, 348160, 261120, 208896, 174080, 149211, 130560, 116053, 104448,  94953,  87040,  80345,  74606,  69632,
     65280,  61440,  58027,  54973,  52224,  49737,  47476,  45412,  43520,  41779,  40172,  38684,  37303,  36017,  34816,  33693,
     32640,  31651,  30720,  29842,  29013,  28229,  27486,  26782,  26112,  25475,  24869,  24290,  23738,  23211,  22706,  22223,
     21760,  21316,  20890,  20480,  20086,  19707,  19342,  18991,  18651,  18324,  18008,  17703,  17408,  17123,  16846,  16579,
     16320,  16069,  15825,  15589,  15360,  15137,  14921,  14711,  14507,  14308,  14115,  13926,  13743,  13565,  13391,  13221,
     13056,  12895,  12738,  12584,  12434,  12288,  12145,  12006,  11869,  11736,  11605,  11478,  11353,  11231,  11111,  10995,
     10880,  10768,  10658,  10550,  10445,  10341,  10240,  10141,  10043,   9947,   9854,   9761,   9671,   9582,   9495,   9410,
      9326,   9243,   9162,   9082,   9004,   8927,   8852,   8777,   8704,   8632,   8561,   8492,   8423,   8356,   8290,   8224,
      8160,   8097,   8034,   7973,   7913,   7853,   7795,   7737,   7680,   7624,   7569,   7514,   7461,   7408,   7355,   7304,
      7253,   7203,   7154,   7105,   7057,   7010,   6963,   6917,   6872,   6827,   6782,   6739,   6695,   6653,   6611,   6569,
      6528,   6487,   6447,   6408,   6369,   6330,   6292,   6254,   6217,   6180,   6144,   6108,   6073,   6037,   6003,   5968,
      5935,   5901,   5868,   5835,   5803,   5771,   5739,   5708,   5677,   5646,   5615,   5585,   5556,   5526,   5497,   5468,
      5440,   5412,   5384,   5356,   5329,   5302,   5275,   5249,   5222,   5196,   5171,   5145,   5120,   5095,   5070,   5046,
      5022,   4998,   4974,   4950,   4927,   4904,   4881,   4858,   4836,   4813,   4791,   4769,   4748,   4726,   4705,   4684,
      4663,   4642,   4622,   4601,   4581,   4561,   4541,   4522,   4502,   4483,   4464,   4445,   4426,   4407,   4389,   4370,
      4352,   4334,   4316,   4298,   4281,   4263,   4246,   4229,   4212,   4195,   4178,   4161,   4145,   4128,   4112,   4096
};

void tl_params_default(tl_params_t *p) {
    p->roi_y_max_frac = 0.6;
    p->red.h_lo = 218;
    p->red.h_hi = 10;
    p->red.s_min = 75;
    p->red.v_min = 120;

    p->yellow.h_lo = 12;
    p->yellow.h_hi = 45;
    p->yellow.s_min = 100;
    p->yellow.v_min = 130;

    p->green.h_lo = 100;
    p->green.h_hi = 135;
    p->green.s_min = 100;
    p->green.v_min = 130;

    p->bloom_v = 245;
    p->close_kernel = 3;
    p->min_w = 8;
    p->min_h = 8;
    p->max_w = 100;
    p->max_h = 80;
    p->min_area = 25;
    p->min_fill = 0.25;
    p->aspect_min = 0.4;
    p->aspect_max = 2.5;
    p->housing_dark_v = 80;
    p->housing_dark_frac = 0.35;
    p->housing_expand_x = 1.0;
    p->housing_expand_y = 0.5;
    p->row_drop_factor = 3.0;
    p->shape_min_size = 10;
    p->shape_round_fill = 0.6;
    p->shape_arrow_ratio = 1.4;
    p->filter_k = 3;
    p->hold_moving_s = 2.0;
    p->housing_mode = TL_HOUSING_SIDE;
    p->housing_side_v = 110;
    p->lamp_v_min = 145;
    p->center_fill_min = 0.3;
    p->arrow_aspect_min = 0.7;
    p->arrow_aspect_max = 1.45;
    p->round_first = 1;
}

const char *tl_color_name(tl_color_t c) {
    switch (c) {
        case TL_COLOR_RED: return "red";
        case TL_COLOR_YELLOW: return "yellow";
        case TL_COLOR_GREEN: return "green";
        case TL_COLOR_NONE:
        default: return "none";
    }
}

const char *tl_shape_name(tl_shape_t s) {
    switch (s) {
        case TL_SHAPE_ROUND: return "round";
        case TL_SHAPE_LEFT: return "left";
        case TL_SHAPE_STRAIGHT: return "straight";
        case TL_SHAPE_RIGHT: return "right";
        case TL_SHAPE_UNKNOWN:
        default: return "unknown";
    }
}

tl_color_t tl_color_from_name(const char *name) {
    if (!name) return TL_COLOR_NONE;
    if (strcmp(name, "red") == 0) return TL_COLOR_RED;
    if (strcmp(name, "yellow") == 0) return TL_COLOR_YELLOW;
    if (strcmp(name, "green") == 0) return TL_COLOR_GREEN;
    return TL_COLOR_NONE;
}

tl_shape_t tl_shape_from_name(const char *name) {
    if (!name) return TL_SHAPE_UNKNOWN;
    if (strcmp(name, "round") == 0) return TL_SHAPE_ROUND;
    if (strcmp(name, "left") == 0) return TL_SHAPE_LEFT;
    if (strcmp(name, "straight") == 0) return TL_SHAPE_STRAIGHT;
    if (strcmp(name, "right") == 0) return TL_SHAPE_RIGHT;
    return TL_SHAPE_UNKNOWN;
}

static inline int uf_find(int *parent, int i) {
    int root = i;
    while (root != parent[root]) {
        root = parent[root];
    }
    int curr = i;
    while (curr != root) {
        int nxt = parent[curr];
        parent[curr] = root;
        curr = nxt;
    }
    return root;
}

static inline void uf_union(int *parent, int a, int b) {
    int root_a = uf_find(parent, a);
    int root_b = uf_find(parent, b);
    if (root_a != root_b) {
        if (root_a < root_b) {
            parent[root_b] = root_a;
        } else {
            parent[root_a] = root_b;
        }
    }
}

static double calc_median_u8(const int hist[256], int total) {
    if (total <= 0) return 255.0;
    int target1 = (total + 1) / 2;
    int target2 = (total % 2 == 0) ? (total / 2 + 1) : target1;
    int acc = 0;
    int v1 = -1, v2 = -1;
    for (int i = 0; i < 256; i++) {
        acc += hist[i];
        if (v1 < 0 && acc >= target1) v1 = i;
        if (v2 < 0 && acc >= target2) { v2 = i; break; }
    }
    return 0.5 * (v1 + v2);
}

static double median_rect_vc(const uint8_t *vc, int w, int x0, int y0, int x1, int y1) {
    if (x1 <= x0 || y1 <= y0) return 255.0;
    int hist[256] = {0};
    int tot = 0;
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            hist[vc[y * w + x]]++;
            tot++;
        }
    }
    return calc_median_u8(hist, tot);
}

static tl_shape_t determine_shape(const int *labels, int img_w, int x, int y,
                                  int w, int h, int area, int cid, const tl_params_t *p) {
    if (w < p->shape_min_size || h < p->shape_min_size) {
        return TL_SHAPE_UNKNOWN;
    }

    int row_w[128] = {0};
    int col_h[128] = {0};
    if (h > 128 || w > 128) return TL_SHAPE_UNKNOWN;

    for (int dr = 0; dr < h; dr++) {
        for (int dc = 0; dc < w; dc++) {
            if (labels[(y + dr) * img_w + (x + dc)] == cid) {
                row_w[dr]++;
                col_h[dc]++;
            }
        }
    }

    int n3r = h / 3;
    if (n3r < 1) n3r = 1;
    int n3c = w / 3;
    if (n3c < 1) n3c = 1;

    int sum_top = 0;
    for (int i = 0; i < n3r; i++) sum_top += row_w[i];
    int sum_bot = 0;
    for (int i = h - n3r; i < h; i++) sum_bot += row_w[i];

    int sum_left = 0;
    for (int i = 0; i < n3c; i++) sum_left += col_h[i];
    int sum_right = 0;
    for (int i = w - n3c; i < w; i++) sum_right += col_h[i];

    double top_w = (double)sum_top / (double)n3r;
    double bot_w = (double)sum_bot / (double)n3r;
    double left_h = (double)sum_left / (double)n3c;
    double right_h = (double)sum_right / (double)n3c;
    double fill = (double)area / (double)(w * h);

    if (p->round_first && fill >= p->shape_round_fill) {
        return TL_SHAPE_ROUND;
    }

    double aspect = (double)w / (double)h;
    if (!(aspect >= p->arrow_aspect_min && aspect <= p->arrow_aspect_max)) {
        return (fill >= p->shape_round_fill) ? TL_SHAPE_ROUND : TL_SHAPE_UNKNOWN;
    }

    double r = p->shape_arrow_ratio;
    if (right_h > 0.0 && left_h >= r * right_h) {
        return TL_SHAPE_LEFT;
    }
    if (left_h > 0.0 && right_h >= r * left_h) {
        return TL_SHAPE_RIGHT;
    }
    if (bot_w > 0.0 && top_w >= r * bot_w) {
        return TL_SHAPE_STRAIGHT;
    }
    if (fill >= p->shape_round_fill) {
        return TL_SHAPE_ROUND;
    }
    return TL_SHAPE_UNKNOWN;
}

typedef struct {
    int x_min;
    int y_min;
    int x_max;
    int y_max;
    int area;
} comp_stat_internal_t;

static int compare_doubles(const void *a, const void *b) {
    double da = *(const double *)a;
    double db = *(const double *)b;
    return (da > db) - (da < db);
}

/* Reusable static buffers to avoid malloc/free overhead per frame */
static int s_buf_N = 0;
static uint8_t *s_hc = NULL;
static uint8_t *s_sc = NULL;
static uint8_t *s_vc = NULL;
static uint8_t *s_mask = NULL;
static uint8_t *s_dil = NULL;
static uint8_t *s_close_mask = NULL;
static int *s_labels = NULL;
static int *s_parent = NULL;
static int *s_remap = NULL;
static comp_stat_internal_t *s_stats = NULL;

static tl_box_t *s_lights_pool = NULL;
static int s_lights_pool_cap = 0;

int tl_detect(const unsigned char *bgr, int w, int h, const tl_params_t *p, tl_box_t *out, int max_boxes) {
    int roi_h = (int)(h * p->roi_y_max_frac);
    if (roi_h < 1) roi_h = h;
    int N = w * roi_h;

    if (N > s_buf_N) {
        free(s_hc); free(s_sc); free(s_vc); free(s_mask); free(s_dil); free(s_close_mask);
        free(s_labels); free(s_parent); free(s_remap); free(s_stats);

        s_hc = (uint8_t *)malloc((size_t)N);
        s_sc = (uint8_t *)malloc((size_t)N);
        s_vc = (uint8_t *)malloc((size_t)N);
        s_mask = (uint8_t *)malloc((size_t)N);
        s_dil = (uint8_t *)malloc((size_t)N);
        s_close_mask = (uint8_t *)malloc((size_t)N);
        s_labels = (int *)malloc((size_t)N * sizeof(int));

        int max_labels = N / 2 + 2;
        s_parent = (int *)malloc((size_t)max_labels * sizeof(int));
        s_remap = (int *)malloc((size_t)max_labels * sizeof(int));
        s_stats = (comp_stat_internal_t *)malloc((size_t)max_labels * sizeof(comp_stat_internal_t));

        if (!s_hc || !s_sc || !s_vc || !s_mask || !s_dil || !s_close_mask || !s_labels || !s_parent || !s_remap || !s_stats) {
            s_buf_N = 0;
            return 0;
        }
        s_buf_N = N;
    }

    if (max_boxes > s_lights_pool_cap) {
        free(s_lights_pool);
        s_lights_pool = (tl_box_t *)malloc((size_t)max_boxes * sizeof(tl_box_t));
        if (!s_lights_pool) {
            s_lights_pool_cap = 0;
            return 0;
        }
        s_lights_pool_cap = max_boxes;
    }

    uint8_t *hc = s_hc;
    uint8_t *sc = s_sc;
    uint8_t *vc = s_vc;
    uint8_t *mask = s_mask;
    uint8_t *dil = s_dil;
    uint8_t *close_mask = s_close_mask;
    int *labels = s_labels;
    int *parent = s_parent;
    int *remap = s_remap;
    comp_stat_internal_t *stats = s_stats;
    int max_labels = s_buf_N / 2 + 2;
    tl_box_t *lights_pool = s_lights_pool;
    int n_lights = 0;

    /* 1. BGR -> HSV_FULL */
    for (int y = 0; y < roi_h; y++) {
        for (int x = 0; x < w; x++) {
            int idx = y * w + x;
            uint8_t b = bgr[idx * 3 + 0];
            uint8_t g = bgr[idx * 3 + 1];
            uint8_t r = bgr[idx * 3 + 2];
            int v = r > g ? (r > b ? r : b) : (g > b ? g : b);
            int vmin = r < g ? (r < b ? r : b) : (g < b ? g : b);
            int d = v - vmin;

            vc[idx] = (uint8_t)v;
            sc[idx] = (v == 0) ? 0 : (uint8_t)((d * sdiv_table[v] + 2048) >> 12);
            if (d == 0) {
                hc[idx] = 0;
            } else {
                int hval;
                if (v == r) {
                    int val = (g - b) * hdiv_table[d];
                    hval = (val + 2048) >> 12;
                    if (hval < 0) hval += 256;
                } else if (v == g) {
                    int h_term = b - r + 2 * d;
                    hval = (h_term * hdiv_table[d] + 2048) >> 12;
                } else {
                    int h_term = r - g + 4 * d;
                    hval = (h_term * hdiv_table[d] + 2048) >> 12;
                }
                if (hval >= 256) hval -= 256;
                if (hval < 0) hval += 256;
                hc[idx] = (uint8_t)hval;
            }
        }
    }

    static const tl_color_t colors[3] = {TL_COLOR_RED, TL_COLOR_YELLOW, TL_COLOR_GREEN};

    for (int ci = 0; ci < 3; ci++) {
        tl_color_t color = colors[ci];
        const tl_color_spec_t *spec = (color == TL_COLOR_RED) ? &p->red :
                                      ((color == TL_COLOR_YELLOW) ? &p->yellow : &p->green);

        /* Color mask */
        int h_lo = spec->h_lo;
        int h_hi = spec->h_hi;
        int s_min = spec->s_min;
        int v_min = spec->v_min;

        if (h_lo > h_hi) {
            for (int i = 0; i < N; i++) {
                uint8_t h_val = hc[i];
                mask[i] = ((h_val >= h_lo || h_val <= h_hi) && sc[i] >= s_min && vc[i] >= v_min) ? 1 : 0;
            }
        } else {
            for (int i = 0; i < N; i++) {
                uint8_t h_val = hc[i];
                mask[i] = ((h_val >= h_lo && h_val <= h_hi) && sc[i] >= s_min && vc[i] >= v_min) ? 1 : 0;
            }
        }

        /* Dilate mask (sq3) */
        for (int y = 0; y < roi_h; y++) {
            int y0 = y > 0 ? y - 1 : 0;
            int y1 = y + 1 < roi_h ? y + 1 : roi_h - 1;
            for (int x = 0; x < w; x++) {
                uint8_t val = 0;
                int x0 = x > 0 ? x - 1 : 0;
                int x1 = x + 1 < w ? x + 1 : w - 1;
                for (int dy = y0; dy <= y1 && !val; dy++) {
                    for (int dx = x0; dx <= x1; dx++) {
                        if (mask[dy * w + dx]) { val = 1; break; }
                    }
                }
                dil[y * w + x] = val;
            }
        }

        /* Bloom: mask | (vc >= bloom_v & dil > 0) */
        int bloom_v = p->bloom_v;
        for (int i = 0; i < N; i++) {
            mask[i] = (mask[i] || (vc[i] >= bloom_v && dil[i])) ? 1 : 0;
        }

        /* Morph close: dilate then erode */
        for (int y = 0; y < roi_h; y++) {
            int y0 = y > 0 ? y - 1 : 0;
            int y1 = y + 1 < roi_h ? y + 1 : roi_h - 1;
            for (int x = 0; x < w; x++) {
                uint8_t val = 0;
                int x0 = x > 0 ? x - 1 : 0;
                int x1 = x + 1 < w ? x + 1 : w - 1;
                for (int dy = y0; dy <= y1 && !val; dy++) {
                    for (int dx = x0; dx <= x1; dx++) {
                        if (mask[dy * w + dx]) { val = 1; break; }
                    }
                }
                dil[y * w + x] = val;
            }
        }
        for (int y = 0; y < roi_h; y++) {
            int y0 = y > 0 ? y - 1 : 0;
            int y1 = y + 1 < roi_h ? y + 1 : roi_h - 1;
            for (int x = 0; x < w; x++) {
                uint8_t val = 1;
                int x0 = x > 0 ? x - 1 : 0;
                int x1 = x + 1 < w ? x + 1 : w - 1;
                for (int dy = y0; dy <= y1 && val; dy++) {
                    for (int dx = x0; dx <= x1; dx++) {
                        if (!dil[dy * w + dx]) { val = 0; break; }
                    }
                }
                close_mask[y * w + x] = val;
            }
        }

        /* Connected components (8-connectivity) */
        memset(labels, 0, (size_t)N * sizeof(int));
        int label_cnt = 0;
        for (int y = 0; y < roi_h; y++) {
            for (int x = 0; x < w; x++) {
                if (!close_mask[y * w + x]) continue;
                int roots[4];
                int n_roots = 0;
                if (y > 0 && x > 0 && labels[(y - 1) * w + (x - 1)] > 0)
                    roots[n_roots++] = uf_find(parent, labels[(y - 1) * w + (x - 1)]);
                if (y > 0 && labels[(y - 1) * w + x] > 0)
                    roots[n_roots++] = uf_find(parent, labels[(y - 1) * w + x]);
                if (y > 0 && x + 1 < w && labels[(y - 1) * w + (x + 1)] > 0)
                    roots[n_roots++] = uf_find(parent, labels[(y - 1) * w + (x + 1)]);
                if (x > 0 && labels[y * w + (x - 1)] > 0)
                    roots[n_roots++] = uf_find(parent, labels[y * w + (x - 1)]);

                if (n_roots == 0) {
                    label_cnt++;
                    if (label_cnt < max_labels) {
                        parent[label_cnt] = label_cnt;
                        labels[y * w + x] = label_cnt;
                    }
                } else {
                    int m = roots[0];
                    for (int k = 1; k < n_roots; k++) {
                        uf_union(parent, m, roots[k]);
                        m = uf_find(parent, m);
                    }
                    labels[y * w + x] = m;
                }
            }
        }

        int num_comp = 0;
        memset(remap, 0, ((size_t)label_cnt + 1) * sizeof(int));
        for (int i = 1; i <= label_cnt; i++) {
            int r = uf_find(parent, i);
            if (remap[r] == 0) remap[r] = ++num_comp;
            remap[i] = remap[r];
        }

        for (int i = 1; i <= num_comp; i++) {
            stats[i].x_min = w;
            stats[i].y_min = roi_h;
            stats[i].x_max = -1;
            stats[i].y_max = -1;
            stats[i].area = 0;
        }

        for (int y = 0; y < roi_h; y++) {
            for (int x = 0; x < w; x++) {
                int lab = labels[y * w + x];
                if (lab > 0) {
                    int cid = remap[lab];
                    labels[y * w + x] = cid;
                    if (x < stats[cid].x_min) stats[cid].x_min = x;
                    if (x > stats[cid].x_max) stats[cid].x_max = x;
                    if (y < stats[cid].y_min) stats[cid].y_min = y;
                    if (y > stats[cid].y_max) stats[cid].y_max = y;
                    stats[cid].area++;
                }
            }
        }

        /* Filter components */
        for (int cid = 1; cid <= num_comp; cid++) {
            int cw = stats[cid].x_max - stats[cid].x_min + 1;
            int ch = stats[cid].y_max - stats[cid].y_min + 1;
            int carea = stats[cid].area;
            int cx = stats[cid].x_min;
            int cy = stats[cid].y_min;

            if (cw < p->min_w || cw > p->max_w) continue;
            if (ch < p->min_h || ch > p->max_h) continue;
            if (carea < p->min_area) continue;

            double aspect = (double)cw / (double)ch;
            if (aspect < p->aspect_min || aspect > p->aspect_max) continue;

            double fill = (double)carea / (double)(cw * ch);
            if (fill < p->min_fill) continue;

            /* Lamp V median */
            int lamp_hist[256] = {0};
            for (int r = 0; r < ch; r++) {
                for (int c = 0; c < cw; c++) {
                    if (labels[(cy + r) * w + (cx + c)] == cid) {
                        lamp_hist[vc[(cy + r) * w + (cx + c)]]++;
                    }
                }
            }
            double lamp_med = calc_median_u8(lamp_hist, carea);
            if (lamp_med < (double)p->lamp_v_min) continue;

            /* Center fill */
            int ch0 = ch / 3;
            int cw0 = cw / 3;
            int center_rows = ch - 2 * ch0;
            int center_cols = cw - 2 * cw0;
            int center_tot = center_rows * center_cols;
            int center_cnt = 0;
            for (int r = ch0; r < ch - ch0; r++) {
                for (int c = cw0; c < cw - cw0; c++) {
                    if (labels[(cy + r) * w + (cx + c)] == cid) {
                        center_cnt++;
                    }
                }
            }
            if (center_tot > 0) {
                double center_fill = (double)center_cnt / (double)center_tot;
                if (center_fill < p->center_fill_min) continue;
            }

            /* Housing check */
            if (p->housing_mode == TL_HOUSING_SIDE) {
                int lx0 = (cx - cw > 0) ? (cx - cw) : 0;
                int rx1 = (cx + 2 * cw < w) ? (cx + 2 * cw) : w;
                double med_l = median_rect_vc(vc, w, lx0, cy, cx, cy + ch);
                double med_r = median_rect_vc(vc, w, cx + cw, cy, rx1, cy + ch);
                double side_v = med_l < med_r ? med_l : med_r;
                if (side_v > (double)p->housing_side_v) continue;

                if (n_lights < max_boxes) {
                    lights_pool[n_lights].x1 = cx;
                    lights_pool[n_lights].y1 = cy;
                    lights_pool[n_lights].x2 = cx + cw;
                    lights_pool[n_lights].y2 = cy + ch;
                    lights_pool[n_lights].color = color;
                    lights_pool[n_lights].shape = determine_shape(labels, w, cx, cy, cw, ch, carea, cid, p);
                    lights_pool[n_lights].area = carea;
                    lights_pool[n_lights].dark_frac = side_v;
                    n_lights++;
                }
            } else {
                int ex = (int)(p->housing_expand_x * (cw > ch ? cw : ch));
                int ey = (int)(p->housing_expand_y * ch);
                int x1e = (cx - ex > 0) ? (cx - ex) : 0;
                int y1e = (cy - ey > 0) ? (cy - ey) : 0;
                int x2e = (cx + cw + ex < w) ? (cx + cw + ex) : w;
                int y2e = (cy + ch + ey < roi_h) ? (cy + ch + ey) : roi_h;
                double dark_frac = 0.0;
                if (x2e > x1e && y2e > y1e) {
                    int ring_tot = 0;
                    int dark_cnt = 0;
                    for (int r = y1e; r < y2e; r++) {
                        for (int c = x1e; c < x2e; c++) {
                            if (r >= cy && r < cy + ch && c >= cx && c < cx + cw) {
                                continue;
                            }
                            ring_tot++;
                            if (vc[r * w + c] < p->housing_dark_v) {
                                dark_cnt++;
                            }
                        }
                    }
                    if (ring_tot > 0) {
                        dark_frac = (double)dark_cnt / (double)ring_tot;
                    }
                }
                if (dark_frac < p->housing_dark_frac) continue;

                if (n_lights < max_boxes) {
                    lights_pool[n_lights].x1 = cx;
                    lights_pool[n_lights].y1 = cy;
                    lights_pool[n_lights].x2 = cx + cw;
                    lights_pool[n_lights].y2 = cy + ch;
                    lights_pool[n_lights].color = color;
                    lights_pool[n_lights].shape = determine_shape(labels, w, cx, cy, cw, ch, carea, cid, p);
                    lights_pool[n_lights].area = carea;
                    lights_pool[n_lights].dark_frac = dark_frac;
                    n_lights++;
                }
            }
        }
    }

    /* Row drop filtering */
    int out_count = 0;
    if (n_lights >= 1) {
        double cys[256];
        double hs_sorted[256];
        int count_eval = n_lights < 256 ? n_lights : 256;
        double y0 = 1e9;
        for (int i = 0; i < count_eval; i++) {
            cys[i] = 0.5 * (lights_pool[i].y1 + lights_pool[i].y2);
            hs_sorted[i] = (double)(lights_pool[i].y2 - lights_pool[i].y1);
            if (cys[i] < y0) y0 = cys[i];
        }
        qsort(hs_sorted, (size_t)count_eval, sizeof(double), compare_doubles);
        double hm;
        if (count_eval % 2 != 0) {
            hm = hs_sorted[count_eval / 2];
        } else {
            hm = 0.5 * (hs_sorted[count_eval / 2 - 1] + hs_sorted[count_eval / 2]);
        }
        double lim = y0 + p->row_drop_factor * hm;
        for (int i = 0; i < count_eval; i++) {
            if (cys[i] <= lim) {
                if (out_count < max_boxes) {
                    out[out_count++] = lights_pool[i];
                }
            }
        }
    }

    return out_count;
}

void tl_associate(const tl_box_t *lights, int n_lights, int out_raw[3]) {
    for (int d = 0; d < 3; d++) {
        tl_shape_t target_shape = (d == 0) ? TL_SHAPE_LEFT : ((d == 1) ? TL_SHAPE_STRAIGHT : TL_SHAPE_RIGHT);
        int sums[4] = {0};
        int has_cand = 0;

        for (int i = 0; i < n_lights; i++) {
            if (lights[i].shape == target_shape) {
                sums[lights[i].color] += lights[i].area;
                has_cand = 1;
            }
        }
        if (!has_cand && (d == 0 || d == 1)) {
            for (int i = 0; i < n_lights; i++) {
                if (lights[i].shape == TL_SHAPE_ROUND || lights[i].shape == TL_SHAPE_UNKNOWN) {
                    sums[lights[i].color] += lights[i].area;
                    has_cand = 1;
                }
            }
        }
        if (!has_cand) {
            out_raw[d] = TL_COLOR_NONE;
            continue;
        }

        static const int prio[4] = {0, 3, 2, 1};
        int best_color = TL_COLOR_NONE;
        int best_area = -1;
        int best_prio = -1;

        for (int c = 1; c <= 3; c++) {
            if (sums[c] > 0) {
                if (sums[c] > best_area || (sums[c] == best_area && prio[c] > best_prio)) {
                    best_area = sums[c];
                    best_prio = prio[c];
                    best_color = c;
                }
            }
        }
        out_raw[d] = best_color;
    }
}

void tl_filter_init(tl_filter_t *f, const tl_params_t *p, double fps_eff) {
    memset(f, 0, sizeof(*f));
    f->dt = 1.0 / fps_eff;
    f->t = 0.0;
    f->filter_k = p->filter_k;
    f->hold_moving_s = p->hold_moving_s;
    for (int d = 0; d < 3; d++) {
        f->st[d].value = TL_COLOR_NONE;
        f->st[d].cand = TL_COLOR_NONE;
        f->st[d].cnt = 0;
        f->st[d].last_non_none_t = -1e9;
    }
}

void tl_filter_update(tl_filter_t *f, const int raw[3], int ego_stopped, int out_sig[3]) {
    f->t += f->dt;
    for (int d = 0; d < 3; d++) {
        tl_channel_filter_t *s = &f->st[d];
        int r = raw[d];
        if (r != TL_COLOR_NONE) {
            s->last_non_none_t = f->t;
            if (r == (int)s->value) {
                s->cnt = 0;
                s->cand = TL_COLOR_NONE;
            } else {
                if (r == (int)s->cand) {
                    s->cnt++;
                } else {
                    s->cand = (tl_color_t)r;
                    s->cnt = 1;
                }
                if (s->cnt >= f->filter_k) {
                    s->value = (tl_color_t)r;
                    s->cnt = 0;
                    s->cand = TL_COLOR_NONE;
                }
            }
        } else {
            if (ego_stopped) {
                /* Vehicle is stopped: hold current signal state */
            } else if (s->value != TL_COLOR_NONE && (f->t - s->last_non_none_t) > f->hold_moving_s) {
                s->value = TL_COLOR_NONE;
                s->cnt = 0;
                s->cand = TL_COLOR_NONE;
            }
        }
        out_sig[d] = (int)s->value;
    }
}
