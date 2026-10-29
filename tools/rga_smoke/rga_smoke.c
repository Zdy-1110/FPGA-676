#include <stdio.h>
#include "im2d.h"

int main(void) {
    const char *version_str = querystring(RGA_VERSION);
    printf("RGA version string: %s\n", version_str);

    rga_buffer_t src = {0};
    rga_buffer_t dst = {0};
    rga_buffer_t pat = {0};
    im_rect srect = {0};
    im_rect drect = {0};
    im_rect prect = {0};

    IM_STATUS status = improcess(src, dst, pat, srect, drect, prect, 0);
    printf("improcess ret: %d\n", (int)status);

    IM_STATUS cvt_status = imcvtcolor(src, dst, RK_FORMAT_RGB_888, RK_FORMAT_RGBA_8888);
    printf("imcvtcolor ret: %d\n", (int)cvt_status);

    return 0;
}
