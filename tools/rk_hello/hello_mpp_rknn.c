/* 交叉编译环境冒烟测试：链接板上的 librockchip_mpp 与 librknnrt（zig cc -target aarch64-linux-gnu.2.36） */
#include <stdio.h>
#include "rk_mpi.h"
#include "rknn_api.h"

int main(void)
{
    MppCtx ctx = NULL; MppApi *mpi = NULL;
    MPP_RET r = mpp_create(&ctx, &mpi);
    if (r == MPP_OK) r = mpp_init(ctx, MPP_CTX_DEC, MPP_VIDEO_CodingHEVC);
    printf("mpp_create + mpp_init(HEVC dec) = %d (0 = OK)\n", r);
    if (ctx) mpp_destroy(ctx);
    rknn_context rc = 0; char junk[64] = {0};
    int k = rknn_init(&rc, junk, sizeof(junk), 0, NULL);
    printf("rknn_init(dummy model) = %d (<0 expected: runtime loaded, model rejected)\n", k);
    return 0;
}
