/*
 * cma_phys_test.c - dma-heap 分配 + /proc/self/pagemap 查物理地址验证程序
 *
 * 用法: cma_phys_test <heap名, 如 cma / system-dma32> <字节数, 十进制或0x十六进制>
 * 验证: dma-heap 缓冲区物理地址是否可查、是否连续、是否位于 4GB 以下。
 * 注: 若交叉编译环境缺少 <linux/dma-heap.h>，下面自动启用自定义定义。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#if defined(__has_include)
#  if __has_include(<linux/dma-heap.h>)
#    include <linux/dma-heap.h>
#  else
#    define USE_LOCAL_DMAHEAP_DEF 1
#  endif
#else
#  define USE_LOCAL_DMAHEAP_DEF 1
#endif

#ifdef USE_LOCAL_DMAHEAP_DEF
/* 编译环境缺少 <linux/dma-heap.h>，此处自定义同 UAPI 布局的结构与 ioctl 号 */
struct dma_heap_allocation_data {
    uint64_t len;
    uint32_t fd;
    uint32_t fd_flags;
    uint64_t heap_flags;
};
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)
#endif

#define FOUR_G  0x100000000ULL

static void die(const char *what)
{
    fprintf(stderr, "%s: %s\n", what, strerror(errno));
    exit(1);
}

int main(int argc, char **argv)
{
    long ps;
    int hfd, pfd;
    char path[128];
    void *buf;
    struct dma_heap_allocation_data data;
    uint64_t len, *pa, mn = UINT64_MAX, mx = 0;
    size_t npages, i, nbad = 0, nbrk = 0, *bad;
    uintptr_t va;
    int all_lt_4g = 1;
    unsigned long long req;

    if (argc != 3) {
        fprintf(stderr, "用法: %s <heap名> <字节数>\n", argv[0]);
        return 1;
    }
    errno = 0;
    req = strtoull(argv[2], NULL, 0);
    if (errno || req == 0) {
        fprintf(stderr, "无效字节数: %s\n", argv[2]);
        return 1;
    }
    ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) die("sysconf(_SC_PAGESIZE)");

    snprintf(path, sizeof(path), "/dev/dma_heap/%s", argv[1]);
    if ((hfd = open(path, O_RDWR | O_CLOEXEC)) < 0) die(path);

    memset(&data, 0, sizeof(data));
    data.len = req;
    data.fd_flags = O_RDWR | O_CLOEXEC;
    data.heap_flags = 0;
    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) die("DMA_HEAP_IOCTL_ALLOC");
    len = data.len;

    buf = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, data.fd, 0);
    if (buf == MAP_FAILED) die("mmap");

    npages = (len + ps - 1) / ps;
    for (i = 0; i < npages; i++)
        ((volatile char *)buf)[i * (size_t)ps] = (char)i;

    if ((pfd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC)) < 0)
        die("/proc/self/pagemap");
    pa = calloc(npages ? npages : 1, sizeof(*pa));
    bad = calloc(npages ? npages : 1, sizeof(*bad));
    if (!pa || !bad) die("calloc");

    va = (uintptr_t)buf;
    for (i = 0; i < npages; i++) {
        uint64_t e = 0, pfn;
        if (pread(pfd, &e, 8, (off_t)((va + i * (uint64_t)ps) / ps) * 8) != 8)
            die("pread pagemap");
        pfn = e & ((1ULL << 55) - 1);
        if (!(e & (1ULL << 63)) || pfn == 0) { bad[nbad++] = i; pa[i] = 0; }
        else pa[i] = pfn * (uint64_t)ps;
    }

    printf("堆=%s 请求=%llu 字节 实际=%llu 字节 页大小=%ld 总页数=%zu\n",
           argv[1], req, (unsigned long long)len, ps, npages);
    printf("第一页物理地址 = 0x%llx\n", (unsigned long long)(npages ? pa[0] : 0));
    printf("最后一页物理地址 = 0x%llx\n",
           (unsigned long long)(npages ? pa[npages - 1] : 0));
    for (i = 0; i < npages; i++) {
        if (pa[i] < mn) mn = pa[i];
        if (pa[i] > mx) mx = pa[i];
        if (pa[i] >= FOUR_G) all_lt_4g = 0;
    }
    printf("最小物理地址 = 0x%llx\n", (unsigned long long)mn);
    printf("最大物理地址 = 0x%llx\n", (unsigned long long)mx);
    printf("全部物理地址 < 4GB : %s\n", all_lt_4g ? "是" : "否");

    printf("不连续断点(前5个):");
    for (i = 1; i < npages; i++) {
        if (pa[i] != pa[0] + i * (uint64_t)ps) {
            nbrk++;
            if (nbrk <= 5)
                printf(" [页%zu 前0x%llx 后0x%llx]", i,
                       (unsigned long long)pa[i - 1], (unsigned long long)pa[i]);
        }
    }
    printf("\nPFN 完全连续 : %s (断点数=%zu)\n", nbrk == 0 ? "是" : "否", nbrk);
    printf("present=0 或 PFN=0 的页数 = %zu\n", nbad);
    if (nbad) {
        printf("异常页号(前5个):");
        for (i = 0; i < nbad && i < 5; i++) printf(" %zu", bad[i]);
        printf("\n");
    }

    free(bad);
    free(pa);
    close(pfd);
    if (munmap(buf, len) < 0) die("munmap");
    close(data.fd);
    close(hfd);
    return 0;
}
