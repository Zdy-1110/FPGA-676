#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>

#if defined(__has_include) && __has_include(<linux/dma-heap.h>)
#include <linux/dma-heap.h>
#else
struct dma_heap_allocation_data {
    uint64_t len;
    uint32_t fd;
    uint32_t fd_flags;
    uint64_t heap_flags;
};
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)
#endif

#define DMA_CHUNK_SIZE (256u * 1024u)
#define DMA_TIMEOUT_NS 2000000000ULL

static const size_t k_sel_sizes[4] = { 1036800u, 777600u, 777600u, 777600u };
static const char *k_sel_names[4] = {
    "sel0.rgb565",
    "sel1.nv12",
    "sel2.nv12",
    "sel3.nv12"
};

static volatile sig_atomic_t g_stop = 0;

static inline uint32_t rd(volatile uint32_t *b, uint32_t off)
{
    return b[off / 4];
}

static inline void wr(volatile uint32_t *b, uint32_t off, uint32_t val)
{
    b[off / 4] = val;
}

static inline uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void sig_handler(int sig)
{
    (void)sig;
    g_stop = 1;
}

static void print_usage(const char *prog)
{
    fprintf(stderr, "Usage:\n");
    fprintf(stderr, "  %s [--bar1 0xf0204000] [--dir /userdata/quad/menu] [--start 0|1]\n\n", prog);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  --bar1 ADDR   FPGA BAR1 physical address (default: 0xf0204000)\n");
    fprintf(stderr, "  --dir PATH    Menu assets directory (default: /userdata/quad/menu)\n");
    fprintf(stderr, "  --start 0|1   Initial selected mode (0: Camera, 1: USB video, default: 0)\n");
    fprintf(stderr, "  -h, --help    Show this help message\n");
}

static int check_phys_range(void *va, size_t len, long ps, uint64_t *out_pa, const char *name)
{
    int pfd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    if (pfd < 0) {
        perror("/proc/self/pagemap");
        return -1;
    }
    size_t npages = (len + (size_t)ps - 1) / (size_t)ps;
    uint64_t first = 0;

    for (size_t k = 0; k < npages; k++) {
        uint64_t e = 0;
        off_t off = (off_t)(((uintptr_t)va + k * (uint64_t)ps) / (uint64_t)ps) * 8;
        if (pread(pfd, &e, 8, off) != 8) {
            fprintf(stderr, "%s page %zu: pagemap read failed\n", name, k);
            close(pfd);
            return -1;
        }
        uint64_t pfn = e & ((1ULL << 55) - 1);
        if (!(e & (1ULL << 63)) || pfn == 0) {
            fprintf(stderr, "%s page %zu: not present\n", name, k);
            close(pfd);
            return -1;
        }
        uint64_t pa = pfn * (uint64_t)ps;
        if (k == 0) {
            first = pa;
        } else if (pa != first + k * (uint64_t)ps) {
            fprintf(stderr, "%s page %zu: PFN not contiguous\n", name, k);
            close(pfd);
            return -1;
        }
    }
    close(pfd);
    if (first + len > 0x100000000ULL) {
        fprintf(stderr, "%s: above 4GB 0x%llx\n", name, (unsigned long long)(first + len));
        return -1;
    }
    if (out_pa) *out_pa = first;
    return 0;
}

static int alloc_dma_buf(const char *name, size_t len, int *out_fd, void **out_va, uint64_t *out_pa)
{
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) {
        perror("sysconf(_SC_PAGESIZE)");
        return -1;
    }

    int hfd = open("/dev/dma_heap/cma", O_RDWR | O_CLOEXEC);
    if (hfd < 0) {
        perror("/dev/dma_heap/cma");
        return -1;
    }

    struct dma_heap_allocation_data data;
    memset(&data, 0, sizeof(data));
    data.len = (len + 4095u) & ~(uint64_t)4095u;
    data.fd_flags = O_RDWR | O_CLOEXEC;
    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) {
        perror("DMA_HEAP_IOCTL_ALLOC");
        close(hfd);
        return -1;
    }
    close(hfd);

    void *va = mmap(NULL, (size_t)data.len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                    (int)data.fd, 0);
    if (va == MAP_FAILED) {
        perror("mmap dma-heap");
        close((int)data.fd);
        return -1;
    }

    if (check_phys_range(va, (size_t)data.len, ps, out_pa, name) < 0) {
        munmap(va, (size_t)data.len);
        close((int)data.fd);
        return -1;
    }

    *out_fd = (int)data.fd;
    *out_va = va;
    return 0;
}

static void clear_all_boxes(volatile uint32_t *bar1)
{
    for (int k = 0; k < 16; k++) {
        wr(bar1, 0x904u + (uint32_t)(k * 8), 0);
        wr(bar1, 0x900u + (uint32_t)(k * 8), 0);
    }
}

static void clear_text_ram(volatile uint32_t *bar1)
{
    for (uint32_t off = 0xC00u; off <= 0xCFCu; off += 4u) {
        wr(bar1, off, 0);
    }
}

static void draw_highlight(volatile uint32_t *bar1, int sel)
{
    // 黄色(3) 2px 框套住选中半屏
    // 左: 8..951, y 8..1071
    // 右: 968..1911, y 8..1071
    uint32_t color = 3u; // 黄色
    uint32_t x0 = (sel == 0) ? 8u : 968u;
    uint32_t y0 = 8u;
    uint32_t x1 = (sel == 0) ? 951u : 1911u;
    uint32_t y1 = 1071u;

    uint32_t lo = ((color & 0xFu) << 28) |
                  (((uint32_t)y0 & 0xFFFu) << 16) |
                  ((uint32_t)x0 & 0xFFFu);
    uint32_t hi = (((uint32_t)y1 & 0xFFFu) << 16) |
                  ((uint32_t)x1 & 0xFFFu);

    wr(bar1, 0x904u, hi);
    wr(bar1, 0x900u, lo);
}

int main(int argc, char **argv)
{
    uint64_t bar1_addr = 0xf0204000ULL;
    const char *dir_path = "/userdata/quad/menu";
    int current_mode = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            print_usage(argv[0]);
            return 0;
        } else if (!strcmp(argv[i], "--bar1")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Missing argument for --bar1\n");
                return 5;
            }
            char *endptr = NULL;
            bar1_addr = strtoull(argv[++i], &endptr, 0);
            if (*endptr != '\0') {
                fprintf(stderr, "Invalid value for --bar1: %s\n", argv[i]);
                return 5;
            }
        } else if (!strcmp(argv[i], "--dir")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Missing argument for --dir\n");
                return 5;
            }
            dir_path = argv[++i];
        } else if (!strcmp(argv[i], "--start")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Missing argument for --start\n");
                return 5;
            }
            char *endptr = NULL;
            long val = strtol(argv[++i], &endptr, 10);
            if (*endptr != '\0' || (val != 0 && val != 1)) {
                fprintf(stderr, "Invalid value for --start: %s (must be 0 or 1)\n", argv[i]);
                return 5;
            }
            current_mode = (int)val;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            return 5;
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sig_handler;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    // 1. 打开 /dev/mem 并映射 BAR1
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    uintptr_t page_base = (uintptr_t)bar1_addr & ~(uintptr_t)0xFFF;
    uintptr_t page_off = (uintptr_t)bar1_addr & (uintptr_t)0xFFF;

    void *map = mmap(NULL, 4096 + page_off, PROT_READ | PROT_WRITE, MAP_SHARED,
                     mem_fd, (off_t)page_base);
    if (map == MAP_FAILED) {
        perror("mmap /dev/mem");
        close(mem_fd);
        return 1;
    }
    volatile uint32_t *bar1 = (volatile uint32_t *)((uint8_t *)map + page_off);

    // 2. 硬件初始化
    // FPGA 复位后写 0x1A0=1 (DDR 门铃使能)
    wr(bar1, 0x1A0u, 1u);

    // FB 四寄存器
    wr(bar1, 0x804u, 0x04000000u);
    wr(bar1, 0x808u, 0x00400000u);
    wr(bar1, 0x80Cu, 960u);
    wr(bar1, 0x810u, 518400u);

    // 0x880=0x10, 清框/文本
    wr(bar1, 0x880u, 0x10u);
    wr(bar1, 0x8C0u, rd(bar1, 0x8C0u) & ~4u);
    wr(bar1, 0x850u, 0);
    clear_text_ram(bar1);
    clear_all_boxes(bar1);

    // 读 0x1C8 作为完成计数基准
    uint32_t g_done_base = rd(bar1, 0x1C8u);
    uint32_t g_seq = 0;

    // 3. 读入 4 个 sel 素材并分配 DMA 缓冲
    int dma_fds[4] = { -1, -1, -1, -1 };
    void *dma_vas[4] = { NULL, NULL, NULL, NULL };
    uint64_t dma_pas[4] = { 0, 0, 0, 0 };

    for (int i = 0; i < 4; i++) {
        char path[512];
        snprintf(path, sizeof(path), "%s/%s", dir_path, k_sel_names[i]);

        struct stat st;
        if (stat(path, &st) != 0 || (size_t)st.st_size != k_sel_sizes[i]) {
            fprintf(stderr, "Error: %s size mismatch or not found (expected %zu, got %ld)\n",
                    path, k_sel_sizes[i], (stat(path, &st) == 0) ? (long)st.st_size : -1L);
            munmap(map, 4096 + page_off);
            close(mem_fd);
            return 3;
        }

        if (alloc_dma_buf(k_sel_names[i], k_sel_sizes[i], &dma_fds[i], &dma_vas[i], &dma_pas[i]) < 0) {
            fprintf(stderr, "Failed to allocate DMA buffer for %s\n", k_sel_names[i]);
            munmap(map, 4096 + page_off);
            close(mem_fd);
            return 1;
        }

        FILE *fp = fopen(path, "rb");
        if (!fp) {
            fprintf(stderr, "Cannot open %s: %s\n", path, strerror(errno));
            munmap(map, 4096 + page_off);
            close(mem_fd);
            return 3;
        }
        size_t nread = fread(dma_vas[i], 1, k_sel_sizes[i], fp);
        fclose(fp);
        if (nread != k_sel_sizes[i]) {
            fprintf(stderr, "Failed to read %zu bytes from %s (got %zu)\n",
                    k_sel_sizes[i], path, nread);
            munmap(map, 4096 + page_off);
            close(mem_fd);
            return 3;
        }
    }

    // 4. 逐槽 DMA 提交素材
    uint32_t fb_base = rd(bar1, 0x804u);
    if (fb_base == 0) fb_base = 0x04000000u;
    uint32_t fb_slot = rd(bar1, 0x808u);
    if (fb_slot == 0) fb_slot = 0x00400000u;

    uint32_t fid = 1u;
    for (int slot = 0; slot < 4; slot++) {
        uint32_t dst_base = fb_base + (uint32_t)slot * fb_slot;
        size_t frame_bytes = k_sel_sizes[slot];
        uint64_t pa = dma_pas[slot];

        for (size_t off = 0; off < frame_bytes; off += DMA_CHUNK_SIZE) {
            uint32_t chunk_len = (uint32_t)(frame_bytes - off);
            if (chunk_len > DMA_CHUNK_SIZE) chunk_len = DMA_CHUNK_SIZE;

            uint64_t t0 = now_ns();
            while ((uint32_t)(g_seq - (uint32_t)(rd(bar1, 0x1C8u) - g_done_base)) >= 16u) {
                if (now_ns() - t0 >= DMA_TIMEOUT_NS) {
                    fprintf(stderr, "DMA chunk timeout on slot %d\n", slot);
                    clear_all_boxes(bar1);
                    munmap(map, 4096 + page_off);
                    close(mem_fd);
                    return 4;
                }
            }

            wr(bar1, 0x190u, (uint32_t)(pa + off));
            wr(bar1, 0x194u, chunk_len);
            wr(bar1, 0x198u, dst_base + (uint32_t)off);
            g_seq++;
            wr(bar1, 0x19Cu, g_seq);
        }

        uint64_t t0 = now_ns();
        while ((uint32_t)(g_seq - (uint32_t)(rd(bar1, 0x1C8u) - g_done_base)) > 0u) {
            if (now_ns() - t0 >= DMA_TIMEOUT_NS) {
                fprintf(stderr, "DMA completion timeout on slot %d\n", slot);
                clear_all_boxes(bar1);
                munmap(map, 4096 + page_off);
                close(mem_fd);
                return 4;
            }
        }

        // 提交 0x814
        wr(bar1, 0x814u, (((fid & 0xFFFFu) << 16) | (uint32_t)slot));
        fid++;
    }

    // 5. 写 0x800=0x65
    wr(bar1, 0x800u, 0x65u);

    // 6. 画初始高亮框
    draw_highlight(bar1, current_mode);

    // 7. 轮询按键 0x844 (每 30 ms)
    uint32_t last_seq = rd(bar1, 0x844u) & 0xFFu;
    int exit_code = 0;

    while (!g_stop) {
        usleep(30000); // 30 ms
        if (g_stop) {
            clear_all_boxes(bar1);
            exit_code = 2;
            break;
        }

        uint32_t v = rd(bar1, 0x844u);
        uint32_t seq = v & 0xFFu;
        if (seq == last_seq) {
            continue;
        }
        last_seq = seq;

        uint32_t key = (v >> 8) & 7u;
        uint32_t type = (v >> 12) & 3u;

        if (type == 1 && key == 0) {
            // KEY0 短按切换左右
            current_mode = 1 - current_mode;
            draw_highlight(bar1, current_mode);
        } else if (type == 1 && key == 1) {
            // KEY1 短按: stdout 打印 0 或 1，清框，退出 0
            clear_all_boxes(bar1);
            printf("%d\n", current_mode);
            fflush(stdout);
            exit_code = 0;
            break;
        } else if ((type == 2 || type == 3) && key == 4) {
            // KEY4 长按/HOLD3: 清框退出 2 (不选)
            clear_all_boxes(bar1);
            exit_code = 2;
            break;
        }
    }

    // 释放资源
    for (int i = 0; i < 4; i++) {
        if (dma_vas[i] && dma_vas[i] != MAP_FAILED) {
            size_t alloc_len = (k_sel_sizes[i] + 4095u) & ~(size_t)4095u;
            munmap(dma_vas[i], alloc_len);
        }
        if (dma_fds[i] >= 0) {
            close(dma_fds[i]);
        }
    }
    munmap(map, 4096 + page_off);
    close(mem_fd);

    return exit_code;
}
