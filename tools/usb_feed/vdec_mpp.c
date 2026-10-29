#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "rk_mpi.h"
#include "rk_mpi_cmd.h"
#include "mpp_buffer.h"
#include "mpp_frame.h"
#include "mpp_packet.h"

#include "vdec_mpp.h"

#if defined(__has_include) && __has_include(<linux/dma-heap.h>)
#include <linux/dma-heap.h>
#else
struct dma_heap_allocation_data { uint64_t len; uint32_t fd; uint32_t fd_flags; uint64_t heap_flags; };
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)
#endif

#define PKT_SIZE (64u * 1024u)
#define FOUR_G 0x100000000ULL

static inline uint64_t vdec_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int check_phys(VDec *d, int idx, void *va, long ps)
{
    int pfd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    size_t npages = (d->buf_len + (size_t)ps - 1) / (size_t)ps, k;
    uint64_t first = 0;
    if (pfd < 0) { perror("/proc/self/pagemap"); return -1; }
    for (k = 0; k < npages; k++) {
        uint64_t e = 0, pfn, pa;
        off_t off = (off_t)(((uintptr_t)va + k * (uint64_t)ps) / (uint64_t)ps) * 8;
        if (pread(pfd, &e, 8, off) != 8) {
            fprintf(stderr, "vdec: buf %d page %zu: pagemap read failed\n", idx, k);
            close(pfd);
            return -1;
        }
        pfn = e & ((1ULL << 55) - 1);
        if (!(e & (1ULL << 63)) || pfn == 0) {
            fprintf(stderr, "vdec: buf %d page %zu: not present\n", idx, k);
            close(pfd);
            return -1;
        }
        pa = pfn * (uint64_t)ps;
        if (k == 0) first = pa;
        else if (pa != first + k * (uint64_t)ps) {
            fprintf(stderr, "vdec: buf %d page %zu: PFN not contiguous\n", idx, k);
            close(pfd);
            return -1;
        }
    }
    close(pfd);
    if (first + d->buf_len > FOUR_G) {
        fprintf(stderr, "vdec: buf %d: above 4GB 0x%llx\n", idx,
                (unsigned long long)(first + d->buf_len));
        return -1;
    }
    return 0;
}

static int alloc_ext_buffers(VDec *d)
{
    char path[128];
    int hfd, i;
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) { perror("sysconf(_SC_PAGESIZE)"); return -1; }
    snprintf(path, sizeof(path), "/dev/dma_heap/%s", d->heap[0] ? d->heap : "cma");
    hfd = open(path, O_RDWR | O_CLOEXEC);
    if (hfd < 0) { perror(path); return -1; }
    d->buf_len = (d->info.buf_size + 4095u) & ~(size_t)4095u;
    for (i = 0; i < d->nbufs; i++) {
        struct dma_heap_allocation_data data;
        MppBufferInfo info;
        void *va;
        memset(&data, 0, sizeof(data));
        data.len = d->buf_len;
        data.fd_flags = O_RDWR | O_CLOEXEC;
        if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) {
            perror("DMA_HEAP_IOCTL_ALLOC");
            close(hfd);
            return -1;
        }
        d->fd[i] = (int)data.fd;
        va = mmap(NULL, d->buf_len, PROT_READ, MAP_SHARED | MAP_POPULATE, d->fd[i], 0);
        if (va == MAP_FAILED) {
            perror("mmap");
            close(hfd);
            return -1;
        }
        if (check_phys(d, i, va, ps) < 0) {
            munmap(va, d->buf_len);
            close(hfd);
            return -1;
        }
        if (munmap(va, d->buf_len) < 0) {
            perror("munmap");
            close(hfd);
            return -1;
        }
        memset(&info, 0, sizeof(info));
        info.type = MPP_BUFFER_TYPE_EXT_DMA;
        info.size = d->buf_len;
        info.fd = d->fd[i];
        info.index = i;
        if (mpp_buffer_commit(d->grp, &info) != MPP_OK) {
            fprintf(stderr, "vdec: mpp_buffer_commit failed at %d\n", i);
            close(hfd);
            return -1;
        }
    }
    d->nbuf = d->nbufs;
    close(hfd);
    return 0;
}

static int handle_info_change(VDec *d, MppFrame frame)
{
    uint32_t w = mpp_frame_get_width(frame);
    uint32_t h = mpp_frame_get_height(frame);
    uint32_t hs = mpp_frame_get_hor_stride(frame);
    uint32_t vs = mpp_frame_get_ver_stride(frame);
    size_t bs = mpp_frame_get_buf_size(frame);
    int fmt = mpp_frame_get_fmt(frame);

    if ((uint32_t)(fmt & MPP_FRAME_FMT_MASK) != (uint32_t)MPP_FMT_YUV420SP) {
        fprintf(stderr, "vdec: unsupported frame fmt 0x%x (want NV12)\n", fmt);
        mpp_frame_deinit(&frame);
        return -1;
    }

    if (!d->have_info) {
        printf("vdec: %ux%u hor_stride=%u ver_stride=%u buf_size=%zu nbufs=%d\n",
               w, h, hs, vs, bs, d->nbufs);
        d->info.w = w;
        d->info.h = h;
        d->info.hs = hs;
        d->info.vs = vs;
        d->info.buf_size = bs;
        if (mpp_buffer_group_get_external(&d->grp, MPP_BUFFER_TYPE_EXT_DMA) != MPP_OK) {
            fprintf(stderr, "vdec: mpp_buffer_group_get_external failed\n");
            mpp_frame_deinit(&frame);
            return -1;
        }
        if (alloc_ext_buffers(d) < 0) {
            mpp_frame_deinit(&frame);
            return -1;
        }
        if (d->mpi->control(d->ctx, MPP_DEC_SET_EXT_BUF_GROUP, d->grp) != MPP_OK) {
            fprintf(stderr, "vdec: MPP_DEC_SET_EXT_BUF_GROUP failed\n");
            mpp_frame_deinit(&frame);
            return -1;
        }
        d->have_info = 1;
    } else if (w != d->info.w || h != d->info.h || hs != d->info.hs ||
               vs != d->info.vs || bs != d->info.buf_size) {
        fprintf(stderr, "vdec: re-init %ux%u hs=%u vs=%u buf=%zu != %ux%u hs=%u vs=%u buf=%zu\n",
                w, h, hs, vs, bs, d->info.w, d->info.h, d->info.hs, d->info.vs, d->info.buf_size);
        mpp_frame_deinit(&frame);
        return -1;
    }

    if (d->mpi->control(d->ctx, MPP_DEC_SET_INFO_CHANGE_READY, NULL) != MPP_OK) {
        fprintf(stderr, "vdec: MPP_DEC_SET_INFO_CHANGE_READY failed\n");
        mpp_frame_deinit(&frame);
        return -1;
    }
    mpp_frame_deinit(&frame);
    return 0;
}

int vdec_open(VDec *d, int codec /*hevc|h264*/, int nbufs, const char *heap)
{
    MppCodingType coding_type;
    MPP_RET rc;
    RK_U32 split;
    RK_S64 timeout;
    int i;

    if (!d) return -1;
    if (codec == 1 || codec == (int)MPP_VIDEO_CodingAVC) {
        coding_type = MPP_VIDEO_CodingAVC;
    } else if (codec == 2 || codec == (int)MPP_VIDEO_CodingHEVC) {
        coding_type = MPP_VIDEO_CodingHEVC;
    } else {
        fprintf(stderr, "vdec_open: unsupported codec %d\n", codec);
        return -1;
    }

    if (nbufs <= 0 || nbufs > VDEC_MAX_BUFS) nbufs = 10;

    memset(d, 0, sizeof(*d));
    for (i = 0; i < VDEC_MAX_BUFS; i++) d->fd[i] = -1;
    d->codec = (int)coding_type;
    d->nbufs = nbufs;
    snprintf(d->heap, sizeof(d->heap), "%s", (heap && heap[0]) ? heap : "cma");

    rc = mpp_create(&d->ctx, &d->mpi);
    if (rc != MPP_OK) {
        fprintf(stderr, "vdec: mpp_create failed: %d\n", rc);
        return -1;
    }

    split = 1;
    d->mpi->control(d->ctx, MPP_DEC_SET_PARSER_SPLIT_MODE, &split);

    rc = mpp_init(d->ctx, MPP_CTX_DEC, coding_type);
    if (rc != MPP_OK) {
        fprintf(stderr, "vdec: mpp_init failed: %d\n", rc);
        vdec_close(d);
        return -1;
    }

    timeout = 5;
    d->mpi->control(d->ctx, MPP_SET_OUTPUT_TIMEOUT, &timeout);

    d->pkt_buf = malloc(PKT_SIZE);
    if (!d->pkt_buf) {
        fprintf(stderr, "vdec: malloc packet buf failed\n");
        vdec_close(d);
        return -1;
    }

    if (mpp_packet_init(&d->packet, d->pkt_buf, PKT_SIZE) != MPP_OK) {
        fprintf(stderr, "vdec: mpp_packet_init failed\n");
        vdec_close(d);
        return -1;
    }

    return 0;
}

int vdec_get_frame(VDec *d, int in_fd, VFrame *f)
{
    if (!d || !d->mpi || !d->ctx || !f) return -1;
    if (d->eos_reached) return 0;

    while (1) {
        /* 1. Try to feed packet if not eos_sent */
        if (!d->eos_sent) {
            if (!d->pkt_pending) {
                ssize_t n;
                do {
                    n = read(in_fd, d->pkt_buf, PKT_SIZE);
                } while (n < 0 && errno == EINTR);
                if (n > 0) {
                    d->pkt_len = (size_t)n;
                    d->pkt_eos = 0;
                    d->pkt_pending = 1;
                } else if (n == 0) {
                    d->pkt_len = 0;
                    d->pkt_eos = 1;
                    d->pkt_pending = 1;
                } else {
                    fprintf(stderr, "vdec: read error: %s\n", strerror(errno));
                    return -1;
                }
            }

            if (d->pkt_pending) {
                mpp_packet_set_pos(d->packet, d->pkt_buf);
                mpp_packet_set_length(d->packet, d->pkt_len);
                if (d->pkt_eos)
                    mpp_packet_set_eos(d->packet);
                else
                    mpp_packet_clr_eos(d->packet);

                if (d->mpi->decode_put_packet(d->ctx, d->packet) == MPP_OK) {
                    d->pkt_pending = 0;
                    if (d->pkt_eos) {
                        d->eos_sent = 1;
                        d->t_eos_sent = vdec_now_ns();
                    }
                }
            }
        }

        /* 2. Try to get a frame from MPP */
        {
            MppFrame frame = NULL;
            MPP_RET gr = d->mpi->decode_get_frame(d->ctx, &frame);
            if (gr == MPP_OK && frame) {
                int eos;
                MppBuffer buf;
                int idx;

                d->t_last_frame = vdec_now_ns();

                if (mpp_frame_get_info_change(frame)) {
                    int hrc = handle_info_change(d, frame);
                    if (hrc != 0) return hrc;
                    continue;
                }

                eos = mpp_frame_get_eos(frame) ? 1 : 0;
                buf = mpp_frame_get_buffer(frame);

                if (eos && !buf) {
                    mpp_frame_deinit(&frame);
                    d->eos_reached = 1;
                    return 0;
                }

                if (mpp_frame_get_errinfo(frame) || mpp_frame_get_discard(frame) || !buf) {
                    mpp_frame_deinit(&frame);
                    if (eos) {
                        d->eos_reached = 1;
                        return 0;
                    }
                    continue;
                }

                idx = mpp_buffer_get_index(buf);
                if (idx < 0 || idx >= d->nbuf) {
                    int fd = mpp_buffer_get_fd(buf);
                    int k;
                    idx = -1;
                    for (k = 0; k < d->nbuf; k++) {
                        if (d->fd[k] == fd) { idx = k; break; }
                    }
                    if (idx < 0) {
                        mpp_frame_deinit(&frame);
                        if (eos) {
                            d->eos_reached = 1;
                            return 0;
                        }
                        continue;
                    }
                }

                f->fd = d->fd[idx];
                f->va = NULL;
                f->width = mpp_frame_get_width(frame);
                f->height = mpp_frame_get_height(frame);
                f->hor_stride = mpp_frame_get_hor_stride(frame);
                f->ver_stride = mpp_frame_get_ver_stride(frame);
                f->index = idx;
                f->frame = frame;

                if (eos) {
                    d->eos_reached = 1;
                }
                return 1;
            }
        }

        /* 3. Timeout after EOS sent */
        if (d->eos_sent) {
            uint64_t t_ref = d->t_eos_sent;
            if (d->t_last_frame > t_ref) t_ref = d->t_last_frame;
            if (vdec_now_ns() - t_ref >= 2000000000ULL) {
                d->eos_reached = 1;
                return 0;
            }
        }

        /* 4. Sleep briefly if packet couldn't be accepted to prevent busy spinning */
        if (d->pkt_pending) {
            struct timespec ts = { 0, 1000000 }; /* 1 ms */
            nanosleep(&ts, NULL);
        }
    }
}

void vdec_release(VDec *d, VFrame *f)
{
    (void)d;
    if (f && f->frame) {
        mpp_frame_deinit(&f->frame);
        f->frame = NULL;
    }
}

int vdec_reset(VDec *d)
{
    if (!d || !d->mpi || !d->ctx) return -1;
    d->mpi->reset(d->ctx);
    d->pkt_pending = 0;
    d->pkt_len = 0;
    d->pkt_eos = 0;
    d->eos_sent = 0;
    d->eos_reached = 0;
    d->t_eos_sent = 0;
    d->t_last_frame = 0;
    return 0;
}

void vdec_close(VDec *d)
{
    int i;
    if (!d) return;
    if (d->mpi && d->ctx) {
        d->mpi->reset(d->ctx);
    }
    if (d->packet) {
        mpp_packet_deinit(&d->packet);
        d->packet = NULL;
    }
    if (d->ctx) {
        mpp_destroy(d->ctx);
        d->ctx = NULL;
    }
    d->mpi = NULL;
    if (d->grp) {
        mpp_buffer_group_put(d->grp);
        d->grp = NULL;
    }
    for (i = 0; i < VDEC_MAX_BUFS; i++) {
        if (d->fd[i] >= 0) {
            close(d->fd[i]);
            d->fd[i] = -1;
        }
    }
    d->nbuf = 0;
    if (d->pkt_buf) {
        free(d->pkt_buf);
        d->pkt_buf = NULL;
    }
}
