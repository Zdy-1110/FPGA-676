#ifndef DMABUF_SYNC_H
#define DMABUF_SYNC_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <errno.h>

#if defined(__has_include) && __has_include(<linux/dma-buf.h>)
#include <linux/dma-buf.h>
#endif

#ifndef DMA_BUF_IOCTL_SYNC
struct dma_buf_sync {
    uint64_t flags;
};
#define DMA_BUF_SYNC_READ  (1 << 0)
#define DMA_BUF_SYNC_WRITE (2 << 0)
#define DMA_BUF_SYNC_RW    (DMA_BUF_SYNC_READ | DMA_BUF_SYNC_WRITE)
#define DMA_BUF_SYNC_START (0 << 2)
#define DMA_BUF_SYNC_END   (1 << 2)
#define DMA_BUF_BASE       'b'
#define DMA_BUF_IOCTL_SYNC _IOW(DMA_BUF_BASE, 0, struct dma_buf_sync)
#endif

static inline void dmabuf_cpu_begin(int fd)
{
    if (fd < 0) return;
    struct dma_buf_sync sync;
    memset(&sync, 0, sizeof(sync));
    sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE;
    if (ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync) < 0) {
        static int s_warned_begin = 0;
        if (!s_warned_begin) {
            s_warned_begin = 1;
            perror("[dmabuf_sync] DMA_BUF_IOCTL_SYNC begin failed");
        }
    }
}

static inline void dmabuf_cpu_end(int fd)
{
    if (fd < 0) return;
    struct dma_buf_sync sync;
    memset(&sync, 0, sizeof(sync));
    sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE;
    if (ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync) < 0) {
        static int s_warned_end = 0;
        if (!s_warned_end) {
            s_warned_end = 1;
            perror("[dmabuf_sync] DMA_BUF_IOCTL_SYNC end failed");
        }
    }
}

/*
 * CMA dma-heap 的 DMA_BUF_IOCTL_SYNC 只对已 attach 的设备做 cache 维护；
 * 我们只把物理地址交给 FPGA（无 attach），ioctl 实际不刷 cache，脏行留在
 * CPU cache 里，FPGA 读到旧数据（屏幕上的绿色/旧画面短横线）。
 * 这里在用户态按 cache line 执行 DC CIVAC（Linux 置 SCTLR_EL1.UCI，EL0 可用），
 * 把 [va, va+len) 写回并失效到 PoC，再 DSB 保证完成后才发门铃。
 */
static inline void dmabuf_flush_range(const void *va, size_t len)
{
#if defined(__aarch64__)
    uint64_t ctr;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
    size_t line = (size_t)4u << ((ctr >> 16) & 0xF);   /* DminLine, bytes */
    uintptr_t p = (uintptr_t)va & ~(uintptr_t)(line - 1);
    uintptr_t end = (uintptr_t)va + len;
    for (; p < end; p += line)
        __asm__ volatile("dc civac, %0" : : "r"(p) : "memory");
    __asm__ volatile("dsb sy" : : : "memory");
#else
    (void)va; (void)len;
#endif
}

/* 写完后调用：先用户态刷 cache，再走 dma-buf ioctl（保留，无害） */
static inline void dmabuf_cpu_end_flush(int fd, const void *va, size_t len)
{
    dmabuf_flush_range(va, len);
    dmabuf_cpu_end(fd);
}

#endif /* DMABUF_SYNC_H */
