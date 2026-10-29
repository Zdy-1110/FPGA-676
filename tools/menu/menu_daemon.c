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

static const char *get_item_text(int item, int npu, int lane, int view, int zebra)
{
    switch (item) {
        case 0: return "1 LIVE 4CAM";
        case 1: return "2 USB VIDEO";
        case 2: return npu ? "3 NPU:ON" : "3 NPU:OFF";
        case 3: return lane ? "4 LANE:ON" : "4 LANE:OFF";
        case 4:
            if (view == 0) return "5 VIEW:COLOR";
            if (view == 1) return "5 VIEW:GRAY";
            return "5 VIEW:BIN";
        case 5: return zebra ? "6 ZEBRA:ON" : "6 ZEBRA:OFF";
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

static void draw_highlight_box(volatile uint32_t *bar1, int sel, int npu, int lane, int view, int zebra)
{
    int row = 1 + sel / 2;
    int col = (sel % 2 == 0) ? 0 : 22;
    const char *text = get_item_text(sel, npu, lane, view, zebra);
    int len = (int)strlen(text);

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

static void show_popup(volatile uint32_t *bar1, int sel, int npu, int lane, int view, int zebra)
{
    write_text_row(bar1, 0, k_header_text);

    for (int r = 1; r <= 3; r++) {
        int left_idx = (r - 1) * 2;
        int right_idx = left_idx + 1;
        const char *sl = get_item_text(left_idx, npu, lane, view, zebra);
        const char *sr = get_item_text(right_idx, npu, lane, view, zebra);
        char row_buf[65];
        memset(row_buf, ' ', 64);
        row_buf[64] = '\0';
        memcpy(row_buf + 0, sl, strlen(sl));
        memcpy(row_buf + 22, sr, strlen(sr));
        write_text_row(bar1, r, row_buf);
    }

    draw_outer_box(bar1);
    draw_highlight_box(bar1, sel, npu, lane, view, zebra);
    clear_extra_boxes(bar1);

    wr(bar1, REG_OSD_CTRL, 0x30u);
}

static void hide_popup(volatile uint32_t *bar1)
{
    clear_text_ram(bar1);
    clear_all_boxes(bar1);
    wr(bar1, REG_OSD_CTRL, 0x10u);
}

static void update_popup_item(volatile uint32_t *bar1, int item_idx, int sel, int npu, int lane, int view, int zebra)
{
    int row = 1 + item_idx / 2;
    int left_idx = (row - 1) * 2;
    int right_idx = left_idx + 1;
    const char *sl = get_item_text(left_idx, npu, lane, view, zebra);
    const char *sr = get_item_text(right_idx, npu, lane, view, zebra);
    char row_buf[65];
    memset(row_buf, ' ', 64);
    row_buf[64] = '\0';
    memcpy(row_buf + 0, sl, strlen(sl));
    memcpy(row_buf + 22, sr, strlen(sr));
    write_text_row(bar1, row, row_buf);

    draw_highlight_box(bar1, sel, npu, lane, view, zebra);
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

static pid_t spawn_feed(const char *feed_bin, const char *bar1_arg, const char *npu_model_arg, int npu_enable)
{
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork feed");
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
        const char *argv[16];
        int argc = 0;
        argv[argc++] = feed_bin;
        argv[argc++] = "--bar1";
        argv[argc++] = bar1_arg;
        argv[argc++] = "--dst";
        argv[argc++] = "960x540";
        argv[argc++] = "--cam";
        argv[argc++] = "/dev/video17:1:30";
        argv[argc++] = "--cam";
        argv[argc++] = "/dev/video19:2:30";
        argv[argc++] = "--cam";
        argv[argc++] = "/dev/video21:3:30";
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
    wr(bar1, REG_MAIN_CTRL, 0x25u);

    // 2. 状态初始化
    int popup = 0;
    int sel = 0;
    int npu = 0;
    int lane = 0;
    int view = 0;
    int zebra = 0;

    // 3. 启动实时 feed（3 路 cam，无 NPU、无 ADAS）
    g_feed_pid = spawn_feed(feed_path, bar1_str_buf, npu_model_path, npu);

    uint32_t last_seq = rd(bar1, REG_KEY) & 0xFFu;
    uint64_t last_feed_check = now_ns();

    while (!g_stop) {
        usleep(30000); // 30 ms
        if (g_stop) break;

        uint64_t t_now = now_ns();
        if (t_now - last_feed_check >= 2000000000ULL) {
            last_feed_check = t_now;
            if (!is_feed_alive(g_feed_pid)) {
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
            // 长按 KEY4（type 2）：弹窗开着则关闭；否则退出回开机选择界面
            if (popup) {
                hide_popup(bar1);
                popup = 0;
            } else {
                g_stop = 1;
            }
            continue;
        } else if (type == 1 && key == 4) {
            // 短按 KEY4：切换弹窗
            popup = !popup;
            if (popup) {
                show_popup(bar1, sel, npu, lane, view, zebra);
            } else {
                hide_popup(bar1);
            }
            continue;
        }

        if (popup && type == 1 && key == 0) {
            // 弹窗内短按 KEY0：sel=(sel+1)%6，重画高亮
            sel = (sel + 1) % 6;
            draw_highlight_box(bar1, sel, npu, lane, view, zebra);
            continue;
        }

        if (popup && type == 1 && key == 1) {
            // 弹窗内短按 KEY1
            if (sel == 0) {
                // 项0 LIVE：确保实时模式（若 feed 死了重启；0x800=0x25）；关弹窗
                hide_popup(bar1);
                popup = 0;
                wr(bar1, REG_MAIN_CTRL, 0x25u);
                if (!is_feed_alive(g_feed_pid)) {
                    g_feed_pid = spawn_feed(feed_path, bar1_str_buf, npu_model_path, npu);
                }
            } else if (sel == 1) {
                // 项1 USB：关弹窗、停 feed、0x800=0x65，若 /userdata/quad/usb_menu 存在则 system() 阻塞运行，返回后恢复实时模式；不存在则在弹窗第 0 行显示 USB MENU NOT INSTALLED 2 秒后恢复
                if (access(k_usb_menu_path, F_OK) == 0) {
                    hide_popup(bar1);
                    popup = 0;
                    kill_feed();
                    wr(bar1, REG_MAIN_CTRL, 0x65u);
                    system(k_usb_menu_path);
                    wr(bar1, REG_MAIN_CTRL, 0x25u);
                    g_feed_pid = spawn_feed(feed_path, bar1_str_buf, npu_model_path, npu);
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
            } else if (sel == 2) {
                // 项2 NPU：npu 取反；重启 feed（加/不加 --npu）
                npu = !npu;
                kill_feed();
                g_feed_pid = spawn_feed(feed_path, bar1_str_buf, npu_model_path, npu);
                last_feed_check = now_ns();
                update_popup_item(bar1, 2, sel, npu, lane, view, zebra);
            } else if (sel == 3) {
                // 项3 LANE：lane 取反；0x8C0 的 bit0/bit1 同时置/清（保留其他位）
                lane = !lane;
                uint32_t val = rd(bar1, REG_LANE_CTRL);
                if (lane) val |= 3u;
                else val &= ~3u;
                wr(bar1, REG_LANE_CTRL, val);
                update_popup_item(bar1, 3, sel, npu, lane, view, zebra);
            } else if (sel == 4) {
                // 项4 VIEW：view=(view+1)%3；0x800 = (0x800 & ~0x300) | (view<<8)（保持其余位）
                view = (view + 1) % 3;
                uint32_t val = rd(bar1, REG_MAIN_CTRL);
                val = (val & ~0x300u) | (((uint32_t)view & 3u) << 8);
                wr(bar1, REG_MAIN_CTRL, val);
                update_popup_item(bar1, 4, sel, npu, lane, view, zebra);
            } else if (sel == 5) {
                // 项5 ZEBRA：zebra 取反；0xA20 bit0
                zebra = !zebra;
                uint32_t val = rd(bar1, REG_ZEBRA_CTRL);
                if (zebra) val |= 1u;
                else val &= ~1u;
                wr(bar1, REG_ZEBRA_CTRL, val);
                update_popup_item(bar1, 5, sel, npu, lane, view, zebra);
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
