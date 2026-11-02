#ifndef LANE_CLS_H
#define LANE_CLS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LANE_RING_SIZE 64
#define LANE_BITSTREAM_CAM20_VER 0x20261103u

typedef struct {
    uint8_t frame_cnt;
    uint8_t max_consec_l;
    uint8_t max_consec_r;
    uint8_t double_cnt_l;
    uint8_t double_cnt_r;
    uint8_t fpga_valid_l;
    uint8_t fpga_solid_l;
    uint8_t fpga_valid_r;
    uint8_t fpga_solid_r;
} LaneSample;

typedef struct {
    int side;           /* 0 = left, 1 = right */
    int valid;          /* 0 or 1 */
    int solid;          /* 0 or 1 */
    uint8_t last_mc;
    uint8_t last_dbl;
    int score;          /* bucket 模式漏桶积分 [0,100] */
} LaneSide;

int lane_cls_start(volatile uint32_t *bar1);
void lane_cls_stop(void);
int lane_cls_get(int *lvalid, int *lsolid, int *rvalid, int *rsolid);

#ifdef LANE_CLS_TEST
void lane_cls_test_init(const char *mode, int w, int ton, int toff, int p);
void lane_cls_update(LaneSide *s, const LaneSample *ring, int n);
uint32_t lane_cls_calc_drop(uint8_t cur_fc, uint8_t last_fc);
#endif

#ifdef __cplusplus
}
#endif

#endif /* LANE_CLS_H */
