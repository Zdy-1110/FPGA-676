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
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/stat.h>

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
#define SLOT0_BYTES    1036800u
#define SLOT123_BYTES  777600u

#define REG_MAIN_CTRL   0x800u
#define REG_KEY         0x844u
#define REG_STATUS      0x848u
#define REG_DECISION    0x850u
#define REG_OSD_CTRL    0x880u
#define REG_LANE_CTRL   0x8C0u
#define REG_BOX_BASE    0x900u
#define REG_ZEBRA_CTRL  0xA20u
#define REG_TEXT_BASE   0xC00u

static const char *k_default_feed_path = "/userdata/quad/usb_feed";
static const char *k_default_npu_model = "/userdata/quad/b5_v6n_band.rknn";
static const char *k_usb_menu_path     = "/userdata/quad/usb_menu";
static const char *k_header_text       = "ADAS MENU   KEY0 NEXT  KEY1 OK  KEY4 HOLD CLOSE";

static volatile sig_atomic_t g_stop = 0;
static pid_t g_feed_pid = -1;
static int g_cam_on[3] = {0, 0, 0};

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
    printf("Usage:\n");
    printf("  %s [options]\n\n", prog);
    printf("Options:\n");
    printf("  --bar1 ADDR        FPGA BAR1 physical address (default: 0xf0204000)\n");
    printf("  --feed PATH        Path to usb_feed binary (default: /userdata/quad/usb_feed)\n");
    printf("  --npu-model PATH   Path to NPU RKNN model (default: /userdata/quad/b5_v6n_band.rknn)\n");
    printf("  -h, --help         Show this help message\n");
}

static void clear_text_ram(volatile uint32_t *bar1)
{
    for (uint32_t off = 0xC00u; off <= 0xCFCu; off += 4u) {
        wr(bar1, off, 0);
    }
}

static void clear_all_boxes(volatile uint32_t *bar1)
{
    for (int k = 0; k < 16; k++) {
        wr(bar1, 0x904u + (uint32_t)(k * 8), 0);
        wr(bar1, 0x900u + (uint32_t)(k * 8), 0);
    }
}

static void clear_extra_boxes(volatile uint32_t *bar1)
{
    for (int k = 2; k < 16; k++) {
        wr(bar1, 0x904u + (uint32_t)(k * 8), 0);
        wr(bar1, 0x900u + (uint32_t)(k * 8), 0);
    }
}

static void write_text_row(volatile uint32_t *bar1, int row_idx, const char *text)
{
    if (row_idx < 0 || row_idx > 3) return;
    uint32_t base = REG_TEXT_BASE + (uint32_t)row_idx * 0x40u;
    char buf[64];
    size_t len = strlen(text);
    if (len > 64) len = 64;
    memcpy(buf, text, len);
    if (len < 64) {
        memset(buf + len, ' ', 64 - len);
    }
    for (int i = 0; i < 16; i++) {
        uint32_t dw = (uint8_t)buf[i * 4 + 0] |
                      ((uint8_t)buf[i * 4 + 1] << 8) |
                      ((uint8_t)buf[i * 4 + 2] << 16) |
                      ((uint8_t)buf[i * 4 + 3] << 24);
        wr(bar1, base + (uint32_t)(i * 4), dw);
    }
}

static const char *get_item_text(int item, const int *cam_on, int npu, int lane, int view, int zebra)
{
    switch (item) {
        case 0: return cam_on[0] ? "1 CAM1:ON" : "1 CAM1:OFF";
        case 1: return cam_on[1] ? "2 CAM2:ON" : "2 CAM2:OFF";
        case 2: return cam_on[2] ? "3 CAM3:ON" : "3 CAM3:OFF";
        case 3: return npu ? "4 NPU:ON" : "4 NPU:OFF";
        case 4: return lane ? "5 LANE:ON" : "5 LANE:OFF";
        case 5:
            if (view == 0) return "6 VIEW:COLOR";
            if (view == 1) return "6 VIEW:GRAY";
            return "6 VIEW:BIN";
        case 6: return zebra ? "7 ZEBRA:ON" : "7 ZEBRA:OFF";
        case 7: return "8 USB VIDEO";
        default: return "";
    }
}

static void draw_outer_box(volatile uint32_t *bar1)
{
    uint32_t color = 5u; // 青色
    uint32_t x0 = 8u, y0 = 8u, x1 = 1056u, y1 = 204u;
    uint32_t lo = ((color & 0xFu) << 28) |
                  ((y0 & 0xFFFu) << 16) |
                  (x0 & 0xFFFu);
    uint32_t hi = ((y1 & 0xFFFu) << 16) |
                  (x1 & 0xFFFu);
    wr(bar1, 0x904u, hi);
    wr(bar1, 0x900u, lo);
}

static void draw_highlight_box(volatile uint32_t *bar1, int sel, const int *cam_on, int npu, int lane, int view, int zebra)
{
    int row = 1 + sel / 3;
    int col = (sel % 3) * 21;
    const char *text = get_item_text(sel, cam_on, npu, lane, view, zebra);
    int len = (int)strlen(text);
    if (len > 20) len = 20;

    int x0 = 16 + col * 16 - 2;
    int y0 = 16 + row * 36 - 2;
    int x1 = x0 + len * 16 + 4;
    int y1 = y0 + 36;

    uint32_t color = 3u; // 黄色
    uint32_t lo = ((color & 0xFu) << 28) |
                  (((uint32_t)y0 & 0xFFFu) << 16) |
                  ((uint32_t)x0 & 0xFFFu);
    uint32_t hi = (((uint32_t)y1 & 0xFFFu) << 16) |
                  ((uint32_t)x1 & 0xFFFu);
    wr(bar1, 0x90Cu, hi);
    wr(bar1, 0x908u, lo);
}

static void show_popup(volatile uint32_t *bar1, int sel, const int *cam_on, int npu, int lane, int view, int zebra)
{
    write_text_row(bar1, 0, k_header_text);

    for (int r = 1; r <= 3; r++) {
        char row_buf[65];
        memset(row_buf, ' ', 64);
        row_buf[64] = '\0';
        for (int c = 0; c < 3; c++) {
            int item_idx = (r - 1) * 3 + c;
            if (item_idx >= 8) break;
            const char *st = get_item_text(item_idx, cam_on, npu, lane, view, zebra);
            size_t slen = strlen(st);
            if (slen > 20) slen = 20;
            memcpy(row_buf + c * 21, st, slen);
        }
        write_text_row(bar1, r, row_buf);
    }

    draw_outer_box(bar1);
    draw_highlight_box(bar1, sel, cam_on, npu, lane, view, zebra);
    clear_extra_boxes(bar1);

    wr(bar1, REG_OSD_CTRL, 0x30u);
}

static void hide_popup(volatile uint32_t *bar1)
{
    clear_text_ram(bar1);
    clear_all_boxes(bar1);
    wr(bar1, REG_OSD_CTRL, 0x10u);
}

static void update_popup_item(volatile uint32_t *bar1, int item_idx, int sel, const int *cam_on, int npu, int lane, int view, int zebra)
{
    int row = 1 + item_idx / 3;
    char row_buf[65];
    memset(row_buf, ' ', 64);
    row_buf[64] = '\0';
    for (int c = 0; c < 3; c++) {
        int idx = (row - 1) * 3 + c;
        if (idx >= 8) break;
        const char *st = get_item_text(idx, cam_on, npu, lane, view, zebra);
        size_t slen = strlen(st);
        if (slen > 20) slen = 20;
        memcpy(row_buf + c * 21, st, slen);
    }
    write_text_row(bar1, row, row_buf);

    draw_highlight_box(bar1, sel, cam_on, npu, lane, view, zebra);
}

static int is_feed_alive(pid_t pid)
{
    if (pid <= 0) return 0;
    int status;
    pid_t r = waitpid(pid, &status, WNOHANG);
    if (r == pid || (r == -1 && errno == ECHILD)) {
        return 0;
    }
    return (kill(pid, 0) == 0);
}

static void *g_zero_va = NULL;
static uint64_t g_zero_pa = 0;
static int g_zero_fd = -1;

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

static int wait_dma_idle(volatile uint32_t *bar1, uint32_t ms)
{
    uint64_t t_start = now_ns();
    uint64_t timeout_ns = (uint64_t)ms * 1000000ULL;
    uint64_t stable_required_ns = 20ULL * 1000000ULL; // 20 ms

    uint32_t last_val = rd(bar1, 0x1C8u);
    uint64_t last_change_time = t_start;

    while (1) {
        usleep(5000); // 5 ms 采样
        uint64_t t_now = now_ns();
        uint32_t cur_val = rd(bar1, 0x1C8u);

        if (cur_val != last_val) {
            last_val = cur_val;
            last_change_time = t_now;
        } else if (t_now - last_change_time >= stable_required_ns) {
            return 0;
        }

        if (t_now - t_start >= timeout_ns) {
            return -1;
        }
    }
}

static int dma_push_slot(volatile uint32_t *bar1, uint64_t pa, int slot, size_t bytes)
{
    wait_dma_idle(bar1, 500);

    uint32_t fb_base = rd(bar1, 0x804u);
    if (fb_base == 0) fb_base = 0x04000000u;
    uint32_t fb_slot = rd(bar1, 0x808u);
    if (fb_slot == 0) fb_slot = 0x00400000u;

    uint32_t dst_base = fb_base + (uint32_t)slot * fb_slot;
    uint32_t done_base = rd(bar1, 0x1C8u);
    uint32_t seq = 0;
    static uint32_t s_fid = 1u;

    for (size_t off = 0; off < bytes; off += DMA_CHUNK_SIZE) {
        uint32_t chunk_len = (uint32_t)(bytes - off);
        if (chunk_len > DMA_CHUNK_SIZE) chunk_len = DMA_CHUNK_SIZE;

        uint64_t t0 = now_ns();
        while ((uint32_t)(seq - (uint32_t)(rd(bar1, 0x1C8u) - done_base)) >= 16u) {
            if (now_ns() - t0 >= DMA_TIMEOUT_NS) {
                fprintf(stderr, "DMA chunk timeout on slot %d\n", slot);
                return -1;
            }
        }

        wr(bar1, 0x190u, (uint32_t)(pa + off));
        wr(bar1, 0x194u, chunk_len);
        wr(bar1, 0x198u, dst_base + (uint32_t)off);
        seq++;
        wr(bar1, 0x19Cu, seq);
    }

    uint64_t t0 = now_ns();
    while ((uint32_t)(seq - (uint32_t)(rd(bar1, 0x1C8u) - done_base)) > 0u) {
        if (now_ns() - t0 >= DMA_TIMEOUT_NS) {
            fprintf(stderr, "DMA completion timeout on slot %d\n", slot);
            return -1;
        }
    }

    wr(bar1, 0x814u, (((s_fid & 0xFFFFu) << 16) | ((uint32_t)slot & 0xFFFFu)));
    s_fid++;
    return 0;
}

static int ensure_zero_dma_buf(void)
{
    if (g_zero_va != NULL && g_zero_pa != 0) {
        return 0;
    }
    size_t max_bytes = SLOT0_BYTES;
    if (alloc_dma_buf("zero_black", max_bytes, &g_zero_fd, &g_zero_va, &g_zero_pa) < 0) {
        fprintf(stderr, "[menu_daemon] alloc_dma_buf failed for zero buffer\n");
        return -1;
    }
    (void)g_zero_fd;
    memset(g_zero_va, 0, max_bytes);
    return 0;
}

/* NV12 黑色 = Y 0x00 + UV 0x80；RGB565 黑色 = 全 0。 */
#define NV12_Y_BYTES   (960u * 540u)
#define NV12_UV_BYTES  (960u * 540u / 2u)

static void clear_slot_black(volatile uint32_t *bar1, int slot)
{
    if (slot < 0 || slot > 3) return;
    if (ensure_zero_dma_buf() < 0) {
        fprintf(stderr, "[menu_daemon] clear_slot_black(%d) skipped: no zero buffer\n", slot);
        return;
    }
    size_t bytes = (slot == 0) ? SLOT0_BYTES : SLOT123_BYTES;
    if (slot == 0) {
        memset(g_zero_va, 0x00, SLOT0_BYTES);
    } else {
        memset(g_zero_va, 0x00, NV12_Y_BYTES);
        memset((uint8_t *)g_zero_va + NV12_Y_BYTES, 0x80, NV12_UV_BYTES);
    }
    if (dma_push_slot(bar1, g_zero_pa, slot, bytes) < 0) {
        fprintf(stderr, "[menu_daemon] clear_slot_black(%d) failed\n", slot);
    }
}

static pid_t spawn_feed(const char *feed_bin, const char *bar1_arg, const char *npu_model_arg, int npu_enable)
{
    if (!g_cam_on[0] && !g_cam_on[1] && !g_cam_on[2]) {
        g_feed_pid = -1;
        return -1;
    }
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork feed");
        g_feed_pid = -1;
        return -1;
    }
    if (pid == 0) {
        setpgid(0, 0);
        int log_fd = open("/tmp/menu_feed.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (log_fd >= 0) {
            dup2(log_fd, STDOUT_FILENO);
            dup2(log_fd, STDERR_FILENO);
            close(log_fd);
        }
        const char *argv[32];
        int argc = 0;
        argv[argc++] = feed_bin;
        argv[argc++] = "--bar1";
        argv[argc++] = bar1_arg;
        argv[argc++] = "--dst";
        argv[argc++] = "960x540";
        if (g_cam_on[0]) {
            argv[argc++] = "--cam";
            argv[argc++] = "/dev/video17:1:30";
        }
        if (g_cam_on[1]) {
            argv[argc++] = "--cam";
            argv[argc++] = "/dev/video19:2:30";
        }
        if (g_cam_on[2]) {
            argv[argc++] = "--cam";
            argv[argc++] = "/dev/video21:3:30";
        }
        if (npu_enable && npu_model_arg && npu_model_arg[0] != '\0') {
            argv[argc++] = "--npu";
            argv[argc++] = npu_model_arg;
        }
        argv[argc] = NULL;

        execvp(feed_bin, (char * const *)argv);
        perror("execvp feed");
        _exit(127);
    }
    setpgid(pid, pid);
    g_feed_pid = pid;
    return pid;
}

static void kill_feed(void)
{
    if (g_feed_pid <= 0) return;
    pid_t pid = g_feed_pid;
    g_feed_pid = -1;

    if (kill(-pid, SIGTERM) < 0) {
        kill(pid, SIGTERM);
    }
    int status;
    int dead = 0;
    for (int i = 0; i < 40; i++) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid || (r == -1 && errno == ECHILD)) {
            dead = 1;
            break;
        }
        usleep(50000);
    }
    if (!dead) {
        if (kill(-pid, SIGKILL) < 0) {
            kill(pid, SIGKILL);
        }
        waitpid(pid, &status, 0);
    }
}

int main(int argc, char **argv)
{
    uint64_t bar1_addr = 0xf0204000ULL;
    const char *feed_path = k_default_feed_path;
    const char *npu_model_path = k_default_npu_model;
    char bar1_str_buf[32] = "0xf0204000";

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
            snprintf(bar1_str_buf, sizeof(bar1_str_buf), "0x%llx", (unsigned long long)bar1_addr);
        } else if (!strcmp(argv[i], "--feed")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Missing argument for --feed\n");
                return 5;
            }
            feed_path = argv[++i];
        } else if (!strcmp(argv[i], "--npu-model")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Missing argument for --npu-model\n");
                return 5;
            }
            npu_model_path = argv[++i];
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

    // 1. 启动硬件初始配置
    wr(bar1, REG_OSD_CTRL, 0x10u);
    clear_text_ram(bar1);
    clear_all_boxes(bar1);
    wr(bar1, REG_LANE_CTRL, rd(bar1, REG_LANE_CTRL) & ~4u);
    wr(bar1, REG_DECISION, 0);
    wr(bar1, REG_LANE_CTRL, rd(bar1, REG_LANE_CTRL) & ~3u);
    wr(bar1, REG_ZEBRA_CTRL, rd(bar1, REG_ZEBRA_CTRL) & ~1u);

    // 启动时清槽：写 0x800=0x65 停 FPGA 摄像头通路，清 slot0-3，再写 0x800=0x25 恢复实时
    wr(bar1, REG_MAIN_CTRL, 0x65u);
    for (int s = 0; s < 4; s++) {
        clear_slot_black(bar1, s);
    }
    wr(bar1, REG_MAIN_CTRL, 0x25u);

    // 2. 状态初始化
    int popup = 0;
    int sel = 0;
    int npu = 0;
    int lane = 0;
    int view = 0;
    int zebra = 0;

    // 3. 启动实时 feed（若 g_cam_on 有任意一路为 1 才启动；默认三路全关不启动）
    if (g_cam_on[0] || g_cam_on[1] || g_cam_on[2]) {
        g_feed_pid = spawn_feed(feed_path, bar1_str_buf, npu_model_path, npu);
    } else {
        g_feed_pid = -1;
    }

    uint32_t last_seq = rd(bar1, REG_KEY) & 0xFFu;
    uint64_t last_feed_check = now_ns();

    while (!g_stop) {
        usleep(30000); // 30 ms
        if (g_stop) break;

        uint64_t t_now = now_ns();
        if (t_now - last_feed_check >= 2000000000ULL) {
            last_feed_check = t_now;
            if (g_feed_pid > 0 && !is_feed_alive(g_feed_pid)) {
                fprintf(stderr, "[menu_daemon] feed died, restarting...\n");
                g_feed_pid = spawn_feed(feed_path, bar1_str_buf, npu_model_path, npu);
            }
        }

        uint32_t v = rd(bar1, REG_KEY);
        uint32_t seq = v & 0xFFu;
        if (seq == last_seq) {
            continue;
        }
        last_seq = seq;

        uint32_t key = (v >> 8) & 7u;
        uint32_t type = (v >> 12) & 3u;

        if (type == 3 && key == 4) {
            // HOLD3 KEY4：关闭弹窗；轮询 0x848 bit7 直到清零（最多 31 s）
            if (popup) {
                hide_popup(bar1);
                popup = 0;
            }
            uint64_t t0 = now_ns();
            usleep(50000); // 50 ms 确保 bit7 反映
            while (!g_stop && (now_ns() - t0) < 31ULL * 1000000000ULL) {
                if ((rd(bar1, REG_STATUS) & 0x80u) == 0) {
                    break;
                }
                usleep(100000); // 100 ms
            }
            last_seq = rd(bar1, REG_KEY) & 0xFFu;
            continue;
        } else if (type == 2 && key == 4) {
            // 长按 KEY4（type 2）：无论弹窗是否打开，都退出回开机选择界面
            if (popup) {
                hide_popup(bar1);
                popup = 0;
            }
            g_stop = 1;
            continue;
        } else if (type == 1 && key == 4) {
            // 短按 KEY4：切换弹窗
            popup = !popup;
            if (popup) {
                show_popup(bar1, sel, g_cam_on, npu, lane, view, zebra);
            } else {
                hide_popup(bar1);
            }
            continue;
        }

        if (popup && type == 1 && key == 0) {
            // 弹窗内短按 KEY0：sel=(sel+1)%8，重画高亮
            sel = (sel + 1) % 8;
            draw_highlight_box(bar1, sel, g_cam_on, npu, lane, view, zebra);
            continue;
        }

        if (popup && type == 1 && key == 1) {
            // 弹窗内短按 KEY1
            if (sel >= 0 && sel <= 2) {
                // 项0/1/2：翻转 g_cam_on[i]，重启 feed（全关则 kill 不 spawn）
                g_cam_on[sel] = !g_cam_on[sel];
                kill_feed();
                if (!g_cam_on[sel]) {
                    clear_slot_black(bar1, sel + 1);
                }
                if (g_cam_on[0] || g_cam_on[1] || g_cam_on[2]) {
                    g_feed_pid = spawn_feed(feed_path, bar1_str_buf, npu_model_path, npu);
                }
                last_feed_check = now_ns();
                update_popup_item(bar1, sel, sel, g_cam_on, npu, lane, view, zebra);
            } else if (sel == 3) {
                // 项3 NPU：翻转 NPU，重启 feed
                npu = !npu;
                kill_feed();
                if (g_cam_on[0] || g_cam_on[1] || g_cam_on[2]) {
                    g_feed_pid = spawn_feed(feed_path, bar1_str_buf, npu_model_path, npu);
                }
                last_feed_check = now_ns();
                update_popup_item(bar1, 3, sel, g_cam_on, npu, lane, view, zebra);
            } else if (sel == 4) {
                // 项4 LANE：lane 取反；0x8C0 的 bit0/bit1 同时置/清（保留其他位）
                lane = !lane;
                uint32_t val = rd(bar1, REG_LANE_CTRL);
                if (lane) val |= 3u;
                else val &= ~3u;
                wr(bar1, REG_LANE_CTRL, val);
                update_popup_item(bar1, 4, sel, g_cam_on, npu, lane, view, zebra);
            } else if (sel == 5) {
                // 项5 VIEW：view=(view+1)%3；0x800 = (0x800 & ~0x300) | (view<<8)（保持其余位）
                view = (view + 1) % 3;
                uint32_t val = rd(bar1, REG_MAIN_CTRL);
                val = (val & ~0x300u) | (((uint32_t)view & 3u) << 8);
                wr(bar1, REG_MAIN_CTRL, val);
                update_popup_item(bar1, 5, sel, g_cam_on, npu, lane, view, zebra);
            } else if (sel == 6) {
                // 项6 ZEBRA：zebra 取反；0xA20 bit0
                zebra = !zebra;
                uint32_t val = rd(bar1, REG_ZEBRA_CTRL);
                if (zebra) val |= 1u;
                else val &= ~1u;
                wr(bar1, REG_ZEBRA_CTRL, val);
                update_popup_item(bar1, 6, sel, g_cam_on, npu, lane, view, zebra);
            } else if (sel == 7) {
                // 项7 USB VIDEO：进入 USB VIDEO（保持原逻辑：关闭弹窗、停 feed、运行 usb_menu、返回后恢复实时）
                if (access(k_usb_menu_path, F_OK) == 0) {
                    hide_popup(bar1);
                    popup = 0;
                    kill_feed();
                    wr(bar1, REG_MAIN_CTRL, 0x65u);
                    system(k_usb_menu_path);
                    wr(bar1, REG_MAIN_CTRL, 0x25u);
                    for (int i = 0; i < 3; i++) {
                        if (!g_cam_on[i]) {
                            clear_slot_black(bar1, i + 1);
                        }
                    }
                    if (g_cam_on[0] || g_cam_on[1] || g_cam_on[2]) {
                        g_feed_pid = spawn_feed(feed_path, bar1_str_buf, npu_model_path, npu);
                    } else {
                        g_feed_pid = -1;
                    }
                    last_feed_check = now_ns();
                    last_seq = rd(bar1, REG_KEY) & 0xFFu;
                } else {
                    write_text_row(bar1, 0, "USB MENU NOT INSTALLED");
                    uint64_t t_end = now_ns() + 2ULL * 1000000000ULL;
                    while (!g_stop && now_ns() < t_end) {
                        usleep(50000);
                    }
                    if (!g_stop) {
                        write_text_row(bar1, 0, k_header_text);
                        last_seq = rd(bar1, REG_KEY) & 0xFFu;
                    }
                }
            }
            continue;
        }
    }

    // 退出处理：kill feed、清 OSD、退出
    kill_feed();
    clear_text_ram(bar1);
    clear_all_boxes(bar1);
    wr(bar1, REG_OSD_CTRL, 0x10u);

    munmap(map, 4096 + page_off);
    close(mem_fd);
    return 0;
}
