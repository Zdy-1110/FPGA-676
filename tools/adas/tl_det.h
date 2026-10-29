#ifndef TL_DET_H
#define TL_DET_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    TL_COLOR_NONE = 0,
    TL_COLOR_RED = 1,
    TL_COLOR_YELLOW = 2,
    TL_COLOR_GREEN = 3
} tl_color_t;

typedef enum {
    TL_SHAPE_UNKNOWN = 0,
    TL_SHAPE_ROUND = 1,
    TL_SHAPE_LEFT = 2,
    TL_SHAPE_STRAIGHT = 3,
    TL_SHAPE_RIGHT = 4
} tl_shape_t;

typedef enum {
    TL_HOUSING_RING = 0,
    TL_HOUSING_SIDE = 1
} tl_housing_mode_t;

typedef struct {
    int h_lo;
    int h_hi;
    int s_min;
    int v_min;
} tl_color_spec_t;

typedef struct {
    union {
        double roi_y_max_frac;
        double roi_frac;
    };
    tl_color_spec_t red;
    tl_color_spec_t yellow;
    tl_color_spec_t green;
    int bloom_v;
    int close_kernel;
    int min_w;
    int min_h;
    int max_w;
    int max_h;
    int min_area;
    double min_fill;
    double aspect_min;
    double aspect_max;
    int housing_dark_v;
    double housing_dark_frac;
    double housing_expand_x;
    double housing_expand_y;
    double row_drop_factor;
    int shape_min_size;
    double shape_round_fill;
    double shape_arrow_ratio;
    int filter_k;
    double hold_moving_s;
    tl_housing_mode_t housing_mode;
    int housing_side_v;
    int lamp_v_min;
    double center_fill_min;
    double arrow_aspect_min;
    double arrow_aspect_max;
    int round_first;
} tl_params_t;

typedef struct {
    int x1;
    int y1;
    int x2;
    int y2;
    tl_color_t color;
    tl_shape_t shape;
    int area;
    double dark_frac;
} tl_box_t;

typedef struct {
    tl_color_t value;
    tl_color_t cand;
    int cnt;
    double last_non_none_t;
} tl_channel_filter_t;

typedef struct {
    tl_channel_filter_t st[3]; /* 0: left, 1: straight, 2: right */
    double t;
    double dt;
    int filter_k;
    double hold_moving_s;
} tl_filter_t;

/* Populate tl_params_t with default values corresponding to params.json */
void tl_params_default(tl_params_t *p);

/* Detect traffic lights in BGR image.
 * bgr: 3-channel interleaved BGR888 of dimension w x h
 * w: image width (e.g. 1920)
 * h: image height (e.g. 1080)
 * p: detection parameters
 * out: buffer to store detected light boxes
 * max_boxes: maximum number of boxes to write
 * Returns: number of detected lights written to out
 */
int tl_detect(const unsigned char *bgr, int w, int h, const tl_params_t *p, tl_box_t *out, int max_boxes);

/* Associate detected lights into raw direction decisions.
 * out_raw: array of 3 ints for [left, straight, right] (0 none / 1 red / 2 yellow / 3 green)
 */
void tl_associate(const tl_box_t *lights, int n_lights, int out_raw[3]);

/* Initialize temporal filter */
void tl_filter_init(tl_filter_t *f, const tl_params_t *p, double fps_eff);

/* Update temporal filter with raw direction decisions and ego motion state.
 * raw: array of 3 ints for [left, straight, right]
 * ego_stopped: non-zero if vehicle is stopped, 0 if moving
 * out_sig: array of 3 ints for filtered [left, straight, right]
 */
void tl_filter_update(tl_filter_t *f, const int raw[3], int ego_stopped, int out_sig[3]);

/* Helpers for color and shape string names */
const char *tl_color_name(tl_color_t c);
const char *tl_shape_name(tl_shape_t s);
tl_color_t tl_color_from_name(const char *name);
tl_shape_t tl_shape_from_name(const char *name);

#ifdef __cplusplus
}
#endif

#endif /* TL_DET_H */
