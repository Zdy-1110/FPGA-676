#ifndef USB_NIGHT_H
#define USB_NIGHT_H

#define NIGHT_LUMA_LO       48
#define NIGHT_LUMA_HI       64
#define NIGHT_LUMA_HI_ENH  180
#define NIGHT_HYST_FRAMES    8

int      night_open(const char *dev);      /* 打开 V4L2 设备用于设置 ctrl，失败返回 -1，只警告一次 */
void     night_close(int fd);
int      night_apply(int fd, int level);   /* 0=默认档 1=轻夜视档 2=强夜视档；0 成功，-1 失败，不逐帧打印错误 */
unsigned night_luma(const unsigned char *y, int w, int h, int stride);  /* 每 8 行、每 8 列抽样 */
int      night_hyst(int *state, int *cnt, unsigned mean, unsigned lo, unsigned hi);  /* 滞回，返回新的 state：0=白天 1=夜间 */

#endif /* USB_NIGHT_H */
