#ifndef VDEC_MPP_H
#define VDEC_MPP_H

#include <stdint.h>
#include <stddef.h>
#include "rk_mpi.h"
#include "mpp_frame.h"
#include "mpp_buffer.h"
#include "mpp_packet.h"

#define VDEC_MAX_BUFS 64

typedef struct {
    int fd;
    void *va;
    uint32_t width;
    uint32_t height;
    uint32_t hor_stride;
    uint32_t ver_stride;
    int index;
    MppFrame frame;
} VFrame;

typedef struct {
    MppCtx ctx;
    MppApi *mpi;
    MppPacket packet;
    char *pkt_buf;
    MppBufferGroup grp;
    int nbufs;
    char heap[64];
    int codec;
    int have_info;
    struct {
        uint32_t w, h, hs, vs;
        size_t buf_size;
    } info;
    size_t buf_len;
    int fd[VDEC_MAX_BUFS];
    int nbuf;
    int pkt_pending;
    size_t pkt_len;
    int pkt_eos;
    int eos_sent;
    int eos_reached;
    uint64_t t_eos_sent;
    uint64_t t_last_frame;
} VDec;

int vdec_open(VDec *d, int codec /*hevc|h264*/, int nbufs, const char *heap);
int vdec_get_frame(VDec *d, int in_fd, VFrame *f);
void vdec_release(VDec *d, VFrame *f);
int vdec_reset(VDec *d);
void vdec_close(VDec *d);

#endif /* VDEC_MPP_H */
