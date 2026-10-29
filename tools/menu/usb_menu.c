#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <dirent.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mount.h>

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

#include "ui_assets.h"

#define DMA_CHUNK_SIZE (256u * 1024u)
#define DMA_TIMEOUT_NS 2000000000ULL

#define SCREEN_W 1920
#define SCREEN_H 1080
#define SLOT_W   960
#define SLOT_H   540

#define MAX_ITEMS 1000
#define MAX_VISIBLE_ROWS 15

static const size_t k_tile_sizes[4] = { 1036800u, 777600u, 777600u, 777600u };

typedef struct {
    uint8_t r, g, b;
} rgb_t;

static const rgb_t COLOR_BG          = { 0x0E, 0x16, 0x20 }; // #0E1620 深色底
static const rgb_t COLOR_CYAN        = { 0x22, 0xD3, 0xEE }; // #22D3EE 青色强调
static const rgb_t COLOR_WHITE       = { 0xFF, 0xFF, 0xFF }; // #FFFFFF 白色文字
static const rgb_t COLOR_GRAY        = { 0x94, 0xA3, 0xB8 }; // #94A3B8 灰色副标题
static const rgb_t COLOR_CARD_BG     = { 0x13, 0x1D, 0x2A }; // #131D2A 面板卡片底色
static const rgb_t COLOR_CARD_BORDER = { 0x1E, 0x29, 0x3B }; // #1E293B 面板边框
static const rgb_t COLOR_AMBER       = { 0xF5, 0x9E, 0x0B }; // #F59E0B 警告/提示

typedef enum {
    ITEM_DIR_UP,
    ITEM_DIR,
    ITEM_FILE,
    ITEM_START
} item_type_t;

typedef struct {
    item_type_t type;
    char name[256];
    char full_path[1024];
    uint64_t size_bytes;
} menu_item_t;

typedef enum {
    NOTIF_NONE,
    NOTIF_MAX_VIDEOS,
    NOTIF_NO_USB
} notif_type_t;

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

static void print_usage(const char *prog)
{
    printf("Usage:\n");
    printf("  %s [options]\n\n", prog);
    printf("Options:\n");
    printf("  --bar1 ADDR        FPGA BAR1 physical address (default: 0xf0204000)\n");
    printf("  --mount PATH       USB mount point (default: /mnt/usb)\n");
    printf("  --feed PATH        Path to usb_feed binary (default: /userdata/quad/usb_feed)\n");
    printf("  --npu-model PATH   Path to NPU RKNN model (default: /userdata/quad/b5_v6n_band.rknn)\n");
    printf("  --cjk PATH         Path to CJK font binary (default: /userdata/quad/ui_cjk.bin)\n");
    printf("  -h, --help         Show this help message\n");
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

static int dma_push_slot(volatile uint32_t *bar1, uint32_t dst_base, uint64_t pa, size_t frame_bytes,
                         uint32_t *p_seq, uint32_t done_base, uint32_t fid, int slot)
{
    for (size_t off = 0; off < frame_bytes; off += DMA_CHUNK_SIZE) {
        uint32_t chunk_len = (uint32_t)(frame_bytes - off);
        if (chunk_len > DMA_CHUNK_SIZE) chunk_len = DMA_CHUNK_SIZE;

        uint64_t t0 = now_ns();
        while ((uint32_t)(*p_seq - (uint32_t)(rd(bar1, 0x1C8u) - done_base)) >= 16u) {
            if (now_ns() - t0 >= DMA_TIMEOUT_NS) {
                fprintf(stderr, "DMA chunk timeout on slot %d\n", slot);
                return -1;
            }
        }

        wr(bar1, 0x190u, (uint32_t)(pa + off));
        wr(bar1, 0x194u, chunk_len);
        wr(bar1, 0x198u, dst_base + (uint32_t)off);
        (*p_seq)++;
        wr(bar1, 0x19Cu, *p_seq);
    }

    uint64_t t0 = now_ns();
    while ((uint32_t)(*p_seq - (uint32_t)(rd(bar1, 0x1C8u) - done_base)) > 0u) {
        if (now_ns() - t0 >= DMA_TIMEOUT_NS) {
            fprintf(stderr, "DMA completion timeout on slot %d\n", slot);
            return -1;
        }
    }

    wr(bar1, 0x814u, (((fid & 0xFFFFu) << 16) | (uint32_t)slot));
    return 0;
}

static int dma_push_all_slots(volatile uint32_t *bar1, uint32_t fb_base, uint32_t fb_slot,
                              const uint64_t *pas, const size_t *sizes,
                              uint32_t *p_seq, uint32_t done_base, uint32_t *p_fid)
{
    for (int slot = 0; slot < 4; slot++) {
        uint32_t dst_base = fb_base + (uint32_t)slot * fb_slot;
        if (dma_push_slot(bar1, dst_base, pas[slot], sizes[slot], p_seq, done_base, *p_fid, slot) < 0) {
            return -1;
        }
        (*p_fid)++;
    }
    return 0;
}

static void make_black_frame(void **vas, const size_t *sizes)
{
    // slot 0: RGB565 black (0x0000)
    memset(vas[0], 0, sizes[0]);
    // slot 1..3: NV12 black (Y=16, UV=128)
    for (int s = 1; s < 4; s++) {
        uint8_t *va = (uint8_t *)vas[s];
        memset(va, 16, 518400);        // Y plane
        memset(va + 518400, 128, 259200); // UV plane
    }
}

static void canvas_to_slots(const uint8_t *canvas, void **vas)
{
    // Slot 0: Top-left (0,0)-(960,540) -> RGB565
    uint8_t *dst0 = (uint8_t *)vas[0];
    for (int y = 0; y < SLOT_H; y++) {
        const uint8_t *src_row = canvas + (y * SCREEN_W) * 3;
        uint8_t *dst_row = dst0 + (y * SLOT_W) * 2;
        for (int x = 0; x < SLOT_W; x++) {
            uint8_t r = src_row[x * 3 + 0];
            uint8_t g = src_row[x * 3 + 1];
            uint8_t b = src_row[x * 3 + 2];
            uint16_t v = (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
            dst_row[x * 2 + 0] = (uint8_t)(v & 0xFF);
            dst_row[x * 2 + 1] = (uint8_t)(v >> 8);
        }
    }

    // Slots 1..3: NV12 (BT.601 limited range)
    static const int slot_ox[4] = { 0, SLOT_W, 0, SLOT_W };
    static const int slot_oy[4] = { 0, 0, SLOT_H, SLOT_H };

    for (int s = 1; s < 4; s++) {
        int ox = slot_ox[s];
        int oy = slot_oy[s];
        uint8_t *y_plane = (uint8_t *)vas[s];
        uint8_t *uv_plane = y_plane + (SLOT_W * SLOT_H);

        for (int y = 0; y < SLOT_H; y += 2) {
            const uint8_t *row0 = canvas + ((oy + y) * SCREEN_W + ox) * 3;
            const uint8_t *row1 = canvas + ((oy + y + 1) * SCREEN_W + ox) * 3;
            uint8_t *dst_y0 = y_plane + y * SLOT_W;
            uint8_t *dst_y1 = y_plane + (y + 1) * SLOT_W;
            uint8_t *dst_uv = uv_plane + (y / 2) * SLOT_W;

            for (int x = 0; x < SLOT_W; x += 2) {
                int r00 = row0[(x + 0) * 3 + 0], g00 = row0[(x + 0) * 3 + 1], b00 = row0[(x + 0) * 3 + 2];
                int r01 = row0[(x + 1) * 3 + 0], g01 = row0[(x + 1) * 3 + 1], b01 = row0[(x + 1) * 3 + 2];
                int r10 = row1[(x + 0) * 3 + 0], g10 = row1[(x + 0) * 3 + 1], b10 = row1[(x + 0) * 3 + 2];
                int r11 = row1[(x + 1) * 3 + 0], g11 = row1[(x + 1) * 3 + 1], b11 = row1[(x + 1) * 3 + 2];

                int y00 = 16 + ((16829 * r00 + 33039 * g00 + 6416 * b00 + 32768) >> 16);
                int y01 = 16 + ((16829 * r01 + 33039 * g01 + 6416 * b01 + 32768) >> 16);
                int y10 = 16 + ((16829 * r10 + 33039 * g10 + 6416 * b10 + 32768) >> 16);
                int y11 = 16 + ((16829 * r11 + 33039 * g11 + 6416 * b11 + 32768) >> 16);

                if (y00 < 16) y00 = 16; else if (y00 > 235) y00 = 235;
                if (y01 < 16) y01 = 16; else if (y01 > 235) y01 = 235;
                if (y10 < 16) y10 = 16; else if (y10 > 235) y10 = 235;
                if (y11 < 16) y11 = 16; else if (y11 > 235) y11 = 235;

                dst_y0[x + 0] = (uint8_t)y00;
                dst_y0[x + 1] = (uint8_t)y01;
                dst_y1[x + 0] = (uint8_t)y10;
                dst_y1[x + 1] = (uint8_t)y11;

                int r_avg = (r00 + r01 + r10 + r11 + 2) >> 2;
                int g_avg = (g00 + g01 + g10 + g11 + 2) >> 2;
                int b_avg = (b00 + b01 + b10 + b11 + 2) >> 2;

                int u_sub = 128 + ((-9714 * r_avg - 19070 * g_avg + 28784 * b_avg + 32768) >> 16);
                int v_sub = 128 + ((28784 * r_avg - 24103 * g_avg - 4681 * b_avg + 32768) >> 16);

                if (u_sub < 16) u_sub = 16; else if (u_sub > 240) u_sub = 240;
                if (v_sub < 16) v_sub = 16; else if (v_sub > 240) v_sub = 240;

                dst_uv[x + 0] = (uint8_t)u_sub;
                dst_uv[x + 1] = (uint8_t)v_sub;
            }
        }
    }
}

static void fill_rect(uint8_t *canvas, int x, int y, int w, int h, rgb_t c)
{
    int x0 = (x < 0) ? 0 : x;
    int y0 = (y < 0) ? 0 : y;
    int x1 = (x + w > SCREEN_W) ? SCREEN_W : x + w;
    int y1 = (y + h > SCREEN_H) ? SCREEN_H : y + h;

    for (int cy = y0; cy < y1; cy++) {
        int px = (cy * SCREEN_W + x0) * 3;
        for (int cx = x0; cx < x1; cx++) {
            canvas[px + 0] = c.r;
            canvas[px + 1] = c.g;
            canvas[px + 2] = c.b;
            px += 3;
        }
    }
}

static void draw_rect_outline(uint8_t *canvas, int x, int y, int w, int h, int t, rgb_t c)
{
    fill_rect(canvas, x, y, w, t, c);
    fill_rect(canvas, x, y + h - t, w, t, c);
    fill_rect(canvas, x, y + t, t, h - 2 * t, c);
    fill_rect(canvas, x + w - t, y + t, t, h - 2 * t, c);
}

typedef struct {
    uint32_t cp;
    uint32_t offset;
} __attribute__((packed)) cjk_entry_t;

typedef struct {
    uint32_t count;
    const cjk_entry_t *index;
    const uint8_t *bitmaps;
    uint8_t *file_data;
    size_t file_size;
} cjk_font_t;

static cjk_font_t g_cjk_font;

static int load_cjk_font(cjk_font_t *font, const char *path)
{
    memset(font, 0, sizeof(*font));

    FILE *fp = fopen(path, "rb");
    if (!fp) {
        fprintf(stderr, "Warning: CJK font file not found: %s (falling back to '?')\n", path);
        return -1;
    }

    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    if (sz < 8) {
        fprintf(stderr, "Warning: CJK font file too small: %ld bytes\n", sz);
        fclose(fp);
        return -1;
    }

    uint8_t *buf = malloc((size_t)sz);
    if (!buf) {
        fprintf(stderr, "Warning: Failed to allocate %ld bytes for CJK font\n", sz);
        fclose(fp);
        return -1;
    }

    size_t nread = fread(buf, 1, (size_t)sz, fp);
    fclose(fp);

    if (nread != (size_t)sz) {
        fprintf(stderr, "Warning: Failed to read CJK font file\n");
        free(buf);
        return -1;
    }

    if (memcmp(buf, "CJK1", 4) != 0) {
        fprintf(stderr, "Warning: Invalid CJK font magic: %.4s\n", buf);
        free(buf);
        return -1;
    }

    uint32_t count = (uint32_t)buf[4] | ((uint32_t)buf[5] << 8) |
                     ((uint32_t)buf[6] << 16) | ((uint32_t)buf[7] << 24);

    size_t expected_min = 8 + (size_t)count * sizeof(cjk_entry_t);
    if ((size_t)sz < expected_min) {
        fprintf(stderr, "Warning: CJK font file corrupted (size %zu < %zu)\n", (size_t)sz, expected_min);
        free(buf);
        return -1;
    }

    font->count = count;
    font->index = (const cjk_entry_t *)(buf + 8);
    font->bitmaps = buf + 8 + (size_t)count * sizeof(cjk_entry_t);
    font->file_data = buf;
    font->file_size = (size_t)sz;

    printf("Loaded CJK font: %s (%u glyphs, %zu bytes)\n", path, count, (size_t)sz);
    return 0;
}

static void free_cjk_font(cjk_font_t *font)
{
    if (font && font->file_data) {
        free(font->file_data);
        font->file_data = NULL;
    }
}

static const uint8_t *cjk_lookup_glyph(const cjk_font_t *font, uint32_t cp)
{
    if (!font || !font->index || font->count == 0) {
        return NULL;
    }

    int left = 0;
    int right = (int)font->count - 1;
    while (left <= right) {
        int mid = left + (right - left) / 2;
        const uint8_t *p_entry = (const uint8_t *)&font->index[mid];
        uint32_t mid_cp = (uint32_t)p_entry[0] | ((uint32_t)p_entry[1] << 8) |
                          ((uint32_t)p_entry[2] << 16) | ((uint32_t)p_entry[3] << 24);
        if (mid_cp == cp) {
            uint32_t offset = (uint32_t)p_entry[4] | ((uint32_t)p_entry[5] << 8) |
                              ((uint32_t)p_entry[6] << 16) | ((uint32_t)p_entry[7] << 24);
            return font->bitmaps + offset;
        } else if (mid_cp < cp) {
            left = mid + 1;
        } else {
            right = mid - 1;
        }
    }
    return NULL;
}

static int utf8_decode(const char **pstr, uint32_t *out_cp)
{
    const uint8_t *s = (const uint8_t *)*pstr;
    if (!s || *s == '\0') {
        return 0;
    }

    uint8_t c0 = s[0];
    if (c0 < 0x80) {
        *out_cp = c0;
        *pstr += 1;
        return 1;
    } else if ((c0 & 0xE0) == 0xC0) {
        if ((s[1] & 0xC0) == 0x80) {
            *out_cp = ((uint32_t)(c0 & 0x1F) << 6) | (uint32_t)(s[1] & 0x3F);
            *pstr += 2;
            return 1;
        }
    } else if ((c0 & 0xF0) == 0xE0) {
        if ((s[1] & 0xC0) == 0x80 && (s[2] & 0xC0) == 0x80) {
            *out_cp = ((uint32_t)(c0 & 0x0F) << 12) |
                      ((uint32_t)(s[1] & 0x3F) << 6) |
                      (uint32_t)(s[2] & 0x3F);
            *pstr += 3;
            return 1;
        }
    } else if ((c0 & 0xF8) == 0xF0) {
        if ((s[1] & 0xC0) == 0x80 && (s[2] & 0xC0) == 0x80 && (s[3] & 0xC0) == 0x80) {
            *out_cp = ((uint32_t)(c0 & 0x07) << 18) |
                      ((uint32_t)(s[1] & 0x3F) << 12) |
                      ((uint32_t)(s[2] & 0x3F) << 6) |
                      (uint32_t)(s[3] & 0x3F);
            *pstr += 4;
            return 1;
        }
    }

    *out_cp = '?';
    *pstr += 1;
    return 1;
}

static void draw_char_clip(uint8_t *canvas, int x, int y, char ch, rgb_t fg, int max_x)
{
    if ((uint8_t)ch < UI_ASCII_FIRST || (uint8_t)ch > UI_ASCII_LAST) ch = '?';
    int idx = (int)(uint8_t)ch - UI_ASCII_FIRST;
    const uint8_t *bmp = ui_ascii_bitmaps[idx];

    for (int r = 0; r < UI_ASCII_HEIGHT; r++) {
        int cy = y + r;
        if (cy < 0 || cy >= SCREEN_H) continue;
        const uint8_t *row_bytes = bmp + r * UI_ASCII_PITCH;
        for (int col = 0; col < UI_ASCII_WIDTH; col++) {
            int cx = x + col;
            if (cx < 0 || cx >= SCREEN_W || cx >= max_x) continue;
            int bit = (row_bytes[col / 8] >> (7 - (col % 8))) & 1;
            if (bit) {
                int px = (cy * SCREEN_W + cx) * 3;
                canvas[px + 0] = fg.r;
                canvas[px + 1] = fg.g;
                canvas[px + 2] = fg.b;
            }
        }
    }
}

static void draw_cjk_glyph(uint8_t *canvas, int x, int y, const uint8_t *glyph, rgb_t color, int max_x)
{
    for (int r = 0; r < 26; r++) {
        int cy = y + r;
        if (cy < 0 || cy >= SCREEN_H) continue;
        uint32_t row_bits = (uint32_t)glyph[r * 4 + 0] |
                            ((uint32_t)glyph[r * 4 + 1] << 8) |
                            ((uint32_t)glyph[r * 4 + 2] << 16) |
                            ((uint32_t)glyph[r * 4 + 3] << 24);
        for (int c = 0; c < 26; c++) {
            int cx = x + c;
            if (cx < 0 || cx >= SCREEN_W || cx >= max_x) continue;
            if ((row_bits >> (25 - c)) & 1) {
                int px = (cy * SCREEN_W + cx) * 3;
                canvas[px + 0] = color.r;
                canvas[px + 1] = color.g;
                canvas[px + 2] = color.b;
            }
        }
    }
}

static int text_width_utf8(const char *str)
{
    const char *p = str;
    uint32_t cp = 0;
    int total_w = 0;

    while (utf8_decode(&p, &cp)) {
        if (cp < 0x80) {
            total_w += 17;
        } else {
            const uint8_t *glyph = cjk_lookup_glyph(&g_cjk_font, cp);
            total_w += (glyph ? 28 : 17);
        }
    }
    return total_w;
}

static int draw_text_utf8(uint8_t *canvas, int x, int y, const char *str, rgb_t color, int max_x)
{
    const char *p = str;
    uint32_t cp = 0;
    int cur_x = x;

    while (utf8_decode(&p, &cp)) {
        if (cur_x >= max_x) {
            break;
        }

        if (cp < 0x80) {
            draw_char_clip(canvas, cur_x, y, (char)cp, color, max_x);
            cur_x += 17;
        } else {
            const uint8_t *glyph = cjk_lookup_glyph(&g_cjk_font, cp);
            if (glyph) {
                draw_cjk_glyph(canvas, cur_x, y, glyph, color, max_x);
                cur_x += 28;
            } else {
                draw_char_clip(canvas, cur_x, y, '?', color, max_x);
                cur_x += 17;
            }
        }
    }
    return cur_x;
}

static void draw_text_utf8_truncated_right(uint8_t *canvas, int x, int y, const char *str,
                                          int max_w, rgb_t color, int max_x)
{
    int total_w = text_width_utf8(str);
    if (total_w <= max_w) {
        draw_text_utf8(canvas, x, y, str, color, max_x);
        return;
    }

    int budget = max_w - 51;
    if (budget < 17) budget = 17;

    const char *p = str;
    uint32_t cp = 0;
    int cur_x = x;

    while (p && *p) {
        if (!utf8_decode(&p, &cp)) break;

        int step = (cp < 0x80) ? 17 : (cjk_lookup_glyph(&g_cjk_font, cp) ? 28 : 17);
        if ((cur_x - x) + step > budget) {
            break;
        }

        if (cp < 0x80) {
            draw_char_clip(canvas, cur_x, y, (char)cp, color, max_x);
        } else {
            const uint8_t *glyph = cjk_lookup_glyph(&g_cjk_font, cp);
            if (glyph) {
                draw_cjk_glyph(canvas, cur_x, y, glyph, color, max_x);
            } else {
                draw_char_clip(canvas, cur_x, y, '?', color, max_x);
            }
        }
        cur_x += step;
    }

    draw_char_clip(canvas, cur_x, y, '.', color, max_x);
    cur_x += 17;
    draw_char_clip(canvas, cur_x, y, '.', color, max_x);
    cur_x += 17;
    draw_char_clip(canvas, cur_x, y, '.', color, max_x);
}

static void draw_text_utf8_truncated_left(uint8_t *canvas, int x, int y, const char *str,
                                         int max_w, rgb_t color, int max_x)
{
    int total_w = text_width_utf8(str);
    if (total_w <= max_w) {
        draw_text_utf8(canvas, x, y, str, color, max_x);
        return;
    }

    int budget = max_w - 51;
    if (budget < 17) budget = 17;

    #define MAX_CPS 1024
    int cp_offsets[MAX_CPS];
    int cp_widths[MAX_CPS];
    int count = 0;

    const char *p = str;
    uint32_t cp = 0;
    while (p && *p && count < MAX_CPS) {
        cp_offsets[count] = (int)(p - str);
        if (!utf8_decode(&p, &cp)) break;
        int step = (cp < 0x80) ? 17 : (cjk_lookup_glyph(&g_cjk_font, cp) ? 28 : 17);
        cp_widths[count] = step;
        count++;
    }

    int sum_w = 0;
    int start_idx = count;
    for (int i = count - 1; i >= 0; i--) {
        if (sum_w + cp_widths[i] > budget) {
            break;
        }
        sum_w += cp_widths[i];
        start_idx = i;
    }
    if (start_idx >= count && count > 0) {
        start_idx = count - 1;
    }

    int cur_x = x;
    draw_char_clip(canvas, cur_x, y, '.', color, max_x);
    cur_x += 17;
    draw_char_clip(canvas, cur_x, y, '.', color, max_x);
    cur_x += 17;
    draw_char_clip(canvas, cur_x, y, '.', color, max_x);
    cur_x += 17;

    draw_text_utf8(canvas, cur_x, y, str + cp_offsets[start_idx], color, max_x);
    #undef MAX_CPS
}

static void draw_bitmap(uint8_t *canvas, int x, int y, const ui_bitmap_t *bm, rgb_t fg)
{
    for (int r = 0; r < bm->height; r++) {
        int cy = y + r;
        if (cy < 0 || cy >= SCREEN_H) continue;
        const uint8_t *row_bytes = bm->bitmap + r * bm->pitch;
        for (int col = 0; col < bm->width; col++) {
            int cx = x + col;
            if (cx < 0 || cx >= SCREEN_W) continue;
            int bit = (row_bytes[col / 8] >> (7 - (col % 8))) & 1;
            if (bit) {
                int px = (cy * SCREEN_W + cx) * 3;
                canvas[px + 0] = fg.r;
                canvas[px + 1] = fg.g;
                canvas[px + 2] = fg.b;
            }
        }
    }
}

static int is_mounted(const char *mount_point, char *out_dev, size_t dev_sz)
{
    FILE *fp = fopen("/proc/mounts", "r");
    if (!fp) return 0;
    char line[512];
    int found = 0;
    while (fgets(line, sizeof(line), fp)) {
        char dev[256], mnt[256];
        if (sscanf(line, "%255s %255s", dev, mnt) == 2) {
            if (strcmp(mnt, mount_point) == 0) {
                found = 1;
                if (out_dev && dev_sz > 0) {
                    char *p = strrchr(dev, '/');
                    strncpy(out_dev, p ? p + 1 : dev, dev_sz - 1);
                    out_dev[dev_sz - 1] = '\0';
                }
                break;
            }
        }
    }
    fclose(fp);
    return found;
}

static int try_mount_dev(const char *dev, const char *mount_point)
{
    char cmd[512];
    mkdir(mount_point, 0755);

    snprintf(cmd, sizeof(cmd), "mount -t vfat -o ro,iocharset=utf8 %s %s 2>/dev/null", dev, mount_point);
    if (system(cmd) == 0) return 0;

    snprintf(cmd, sizeof(cmd), "mount -t ntfs -o ro %s %s 2>/dev/null", dev, mount_point);
    if (system(cmd) == 0) return 0;

    snprintf(cmd, sizeof(cmd), "mount -t ntfs3 -o ro %s %s 2>/dev/null", dev, mount_point);
    if (system(cmd) == 0) return 0;

    snprintf(cmd, sizeof(cmd), "mount -o ro %s %s 2>/dev/null", dev, mount_point);
    if (system(cmd) == 0) return 0;

    /* exfat-fuse rejects ro on some sticks ("would change RO state"); retry rw */
    snprintf(cmd, sizeof(cmd), "mount %s %s 2>/dev/null", dev, mount_point);
    if (system(cmd) == 0) return 0;

    return -1;
}

static int scan_and_mount(const char *mount_point, char *out_dev, size_t dev_sz)
{
    if (is_mounted(mount_point, out_dev, dev_sz)) {
        return 0;
    }

    char dev_path[64];
    for (int part = 1; part <= 4; part++) {
        for (char c = 'a'; c <= 'z'; c++) {
            snprintf(dev_path, sizeof(dev_path), "/dev/sd%c%d", c, part);
            if (access(dev_path, F_OK) == 0) {
                if (try_mount_dev(dev_path, mount_point) == 0) {
                    if (out_dev && dev_sz > 0) {
                        snprintf(out_dev, dev_sz, "sd%c%d", c, part);
                    }
                    return 0;
                }
            }
        }
    }

    for (char c = 'a'; c <= 'z'; c++) {
        snprintf(dev_path, sizeof(dev_path), "/dev/sd%c", c);
        if (access(dev_path, F_OK) == 0) {
            if (try_mount_dev(dev_path, mount_point) == 0) {
                if (out_dev && dev_sz > 0) {
                    snprintf(out_dev, dev_sz, "sd%c", c);
                }
                return 0;
            }
        }
    }

    return -1;
}

static void unmount_usb(const char *mount_point)
{
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "umount %s 2>/dev/null", mount_point);
    system(cmd);
}

static int cmp_item_name(const void *a, const void *b)
{
    const menu_item_t *ia = (const menu_item_t *)a;
    const menu_item_t *ib = (const menu_item_t *)b;
    return strcasecmp(ia->name, ib->name);
}

static int get_selection_index(const char *path, char selected_paths[4][1024], int num_selected)
{
    for (int i = 0; i < num_selected; i++) {
        if (strcmp(selected_paths[i], path) == 0) {
            return i;
        }
    }
    return -1;
}

static int is_still_path(const char *path)
{
    size_t len = strlen(path);
    if (len >= 4 && strcasecmp(path + len - 4, ".jpg") == 0) return 1;
    if (len >= 5 && strcasecmp(path + len - 5, ".jpeg") == 0) return 1;
    if (len >= 4 && strcasecmp(path + len - 4, ".png") == 0) return 1;
    if (len >= 4 && strcasecmp(path + len - 4, ".bmp") == 0) return 1;
    return 0;
}

static int is_media_file(const char *name)
{
    size_t len = strlen(name);
    if (len >= 4 && strcasecmp(name + len - 4, ".mp4") == 0) return 1;
    return is_still_path(name);
}

static int scan_directory(const char *dir_path, const char *mount_point,
                          menu_item_t *items, int *out_total_items)
{
    int count = 0;

    if (strcmp(dir_path, mount_point) != 0) {
        items[count].type = ITEM_DIR_UP;
        strcpy(items[count].name, "..");
        snprintf(items[count].full_path, sizeof(items[count].full_path), "%s/..", dir_path);
        items[count].size_bytes = 0;
        count++;
    }

    DIR *d = opendir(dir_path);
    if (!d) {
        // 目录打不开，只加 START
        items[count].type = ITEM_START;
        strcpy(items[count].name, "START");
        items[count].full_path[0] = '\0';
        items[count].size_bytes = 0;
        count++;
        *out_total_items = count;
        return -1;
    }

    menu_item_t *dirs = malloc(MAX_ITEMS * sizeof(menu_item_t));
    menu_item_t *files = malloc(MAX_ITEMS * sizeof(menu_item_t));
    int n_dirs = 0, n_files = 0;

    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] == '.') continue; // 跳过 .、.. 与隐藏文件

        char full[1024];
        snprintf(full, sizeof(full), "%s/%s", dir_path, de->d_name);

        struct stat st;
        if (stat(full, &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            if (n_dirs < MAX_ITEMS) {
                dirs[n_dirs].type = ITEM_DIR;
                strncpy(dirs[n_dirs].name, de->d_name, sizeof(dirs[n_dirs].name) - 1);
                dirs[n_dirs].name[sizeof(dirs[n_dirs].name) - 1] = '\0';
                strncpy(dirs[n_dirs].full_path, full, sizeof(dirs[n_dirs].full_path) - 1);
                dirs[n_dirs].full_path[sizeof(dirs[n_dirs].full_path) - 1] = '\0';
                dirs[n_dirs].size_bytes = 0;
                n_dirs++;
            }
        } else if (S_ISREG(st.st_mode)) {
            if (is_media_file(de->d_name)) {
                if (n_files < MAX_ITEMS) {
                    files[n_files].type = ITEM_FILE;
                    strncpy(files[n_files].name, de->d_name, sizeof(files[n_files].name) - 1);
                    files[n_files].name[sizeof(files[n_files].name) - 1] = '\0';
                    strncpy(files[n_files].full_path, full, sizeof(files[n_files].full_path) - 1);
                    files[n_files].full_path[sizeof(files[n_files].full_path) - 1] = '\0';
                    files[n_files].size_bytes = (uint64_t)st.st_size;
                    n_files++;
                }
            }
        }
    }
    closedir(d);

    if (n_dirs > 1) {
        qsort(dirs, n_dirs, sizeof(menu_item_t), cmp_item_name);
    }
    if (n_files > 1) {
        qsort(files, n_files, sizeof(menu_item_t), cmp_item_name);
    }

    for (int i = 0; i < n_dirs && count < MAX_ITEMS - 1; i++) {
        items[count++] = dirs[i];
    }
    for (int i = 0; i < n_files && count < MAX_ITEMS - 1; i++) {
        items[count++] = files[i];
    }

    free(dirs);
    free(files);

    items[count].type = ITEM_START;
    strcpy(items[count].name, "START");
    items[count].full_path[0] = '\0';
    items[count].size_bytes = 0;
    count++;

    *out_total_items = count;
    return 0;
}

static void render_ui(uint8_t *canvas,
                      const char *current_path,
                      const char *usb_dev,
                      int usb_mounted,
                      const menu_item_t *items,
                      int total_items,
                      int cursor,
                      int top_idx,
                      char selected_paths[4][1024],
                      char selected_names[4][256],
                      int num_selected,
                      notif_type_t notif_type)
{
    fill_rect(canvas, 0, 0, SCREEN_W, SCREEN_H, COLOR_BG);

    // 顶部 (48, 28) 标题与副标题
    draw_bitmap(canvas, 48, 28, &ui_lbl_title, COLOR_WHITE);
    draw_bitmap(canvas, 48 + ui_lbl_title.width + 32, 34, &ui_lbl_subtitle, COLOR_GRAY);

    // 顶部 (48, 84) 路径与挂载设备名
    char path_buf[1024];
    if (usb_mounted && usb_dev && usb_dev[0] != '\0') {
        snprintf(path_buf, sizeof(path_buf), "[%s] %s", usb_dev, current_path);
    } else {
        snprintf(path_buf, sizeof(path_buf), "[NO_USB] %s", current_path);
    }
    draw_text_utf8_truncated_left(canvas, 48, 84, path_buf, 1800, COLOR_GRAY, 1872);

    // 分隔线
    fill_rect(canvas, 48, 122, 120, 4, COLOR_CYAN);
    fill_rect(canvas, 168, 123, SCREEN_W - 48 - 168, 2, COLOR_CARD_BORDER);

    // 左侧列表背景
    fill_rect(canvas, 48, 140, 1132, 780, COLOR_CARD_BG);
    draw_rect_outline(canvas, 48, 140, 1132, 780, 2, COLOR_CARD_BORDER);

    if (!usb_mounted) {
        draw_bitmap(canvas, 80, 300, &ui_lbl_no_usb, COLOR_AMBER);
    } else if (total_items <= 1) {
        draw_text_utf8(canvas, 80, 200, "(空目录，未找到 mp4 文件)", COLOR_GRAY, 1100);
    }

    for (int r = 0; r < MAX_VISIBLE_ROWS; r++) {
        int idx = top_idx + r;
        if (idx >= total_items) break;

        int y_row = 140 + r * 52;
        int y_text = y_row + 13;
        int is_cur = (idx == cursor);

        if (is_cur) {
            fill_rect(canvas, 50, y_row + 2, 1128, 48, COLOR_CYAN);
        }

        const menu_item_t *item = &items[idx];
        rgb_t text_col = is_cur ? COLOR_BG : COLOR_WHITE;

        if (item->type == ITEM_DIR_UP) {
            draw_text_utf8(canvas, 68, y_text, "..", is_cur ? COLOR_BG : COLOR_CYAN, 880);
        } else if (item->type == ITEM_DIR) {
            char dir_text[512];
            snprintf(dir_text, sizeof(dir_text), "[DIR]  %s", item->name);
            draw_text_utf8_truncated_right(canvas, 68, y_text, dir_text, 820, text_col, 900);
        } else if (item->type == ITEM_FILE) {
            draw_text_utf8_truncated_right(canvas, 68, y_text, item->name, 820, text_col, 900);

            char size_str[32];
            uint64_t mb = item->size_bytes / (1024ULL * 1024ULL);
            if (mb > 0) {
                snprintf(size_str, sizeof(size_str), "%4llu MB", (unsigned long long)mb);
            } else {
                snprintf(size_str, sizeof(size_str), "  <1 MB");
            }
            draw_text_utf8(canvas, 920, y_text, size_str, is_cur ? COLOR_BG : COLOR_GRAY, 1050);

            int sel_idx = get_selection_index(item->full_path, selected_paths, num_selected);
            if (sel_idx >= 0) {
                char sel_str[8];
                snprintf(sel_str, sizeof(sel_str), "[%d]", sel_idx + 1);
                draw_text_utf8(canvas, 1070, y_text, sel_str, is_cur ? COLOR_BG : COLOR_CYAN, 1130);
            }
        } else if (item->type == ITEM_START) {
            char start_str[32];
            snprintf(start_str, sizeof(start_str), "> START (%d)", num_selected);
            rgb_t start_col = (num_selected >= 1) ? COLOR_CYAN : COLOR_GRAY;
            draw_text_utf8(canvas, 68, y_text, start_str, is_cur ? COLOR_BG : start_col, 880);
        }
    }

    // 右侧面板 (1220..1872)
    fill_rect(canvas, 1220, 140, 652, 780, COLOR_CARD_BG);
    draw_rect_outline(canvas, 1220, 140, 652, 780, 2, COLOR_CARD_BORDER);

    draw_bitmap(canvas, 1250, 165, &ui_lbl_selected, COLOR_WHITE);
    char sel_count_str[16];
    snprintf(sel_count_str, sizeof(sel_count_str), " %d/4", num_selected);
    draw_text_utf8(canvas, 1250 + ui_lbl_selected.width + 8, 164, sel_count_str, COLOR_CYAN, 1840);

    for (int s = 0; s < 4; s++) {
        int y_slot = 230 + s * 80;
        int y_text = y_slot + 19;
        fill_rect(canvas, 1246, y_slot, 600, 64, COLOR_BG);
        int has_video = (s < num_selected);
        draw_rect_outline(canvas, 1246, y_slot, 600, 64, 1, has_video ? COLOR_CYAN : COLOR_CARD_BORDER);

        char slot_label[8];
        snprintf(slot_label, sizeof(slot_label), "[%d]", s + 1);
        draw_text_utf8(canvas, 1262, y_text, slot_label, has_video ? COLOR_CYAN : COLOR_GRAY, 1310);

        if (has_video) {
            draw_text_utf8_truncated_right(canvas, 1318, y_text, selected_names[s], 500, COLOR_WHITE, 1836);
        } else {
            draw_text_utf8(canvas, 1318, y_text, "(空)", COLOR_GRAY, 1836);
        }
    }

    // 开始播放大按钮
    int is_start_active = (cursor < total_items && items[cursor].type == ITEM_START);
    int y_btn = 600;
    int btn_w = 600;
    int btn_h = 90;
    int x_btn = 1246;

    if (is_start_active) {
        fill_rect(canvas, x_btn, y_btn, btn_w, btn_h, COLOR_CYAN);
        int bx = x_btn + (btn_w - ui_lbl_start_play.width) / 2;
        int by = y_btn + (btn_h - ui_lbl_start_play.height) / 2;
        draw_bitmap(canvas, bx, by, &ui_lbl_start_play, COLOR_BG);
    } else {
        fill_rect(canvas, x_btn, y_btn, btn_w, btn_h, COLOR_BG);
        int can_play = (num_selected >= 1);
        draw_rect_outline(canvas, x_btn, y_btn, btn_w, btn_h, can_play ? 2 : 1, can_play ? COLOR_CYAN : COLOR_CARD_BORDER);
        int bx = x_btn + (btn_w - ui_lbl_start_play.width) / 2;
        int by = y_btn + (btn_h - ui_lbl_start_play.height) / 2;
        draw_bitmap(canvas, bx, by, &ui_lbl_start_play, can_play ? COLOR_CYAN : COLOR_GRAY);
    }

    // 底部状态行 (48, 1000)
    if (!usb_mounted) {
        draw_bitmap(canvas, 48, 1000, &ui_lbl_no_usb, COLOR_AMBER);
    } else if (notif_type == NOTIF_MAX_VIDEOS) {
        draw_bitmap(canvas, 48, 1000, &ui_lbl_max_videos, COLOR_AMBER);
    } else {
        draw_bitmap(canvas, 48, 1000, &ui_lbl_key_hint, COLOR_GRAY);
    }
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

static void kill_pid_gracefully(pid_t pid)
{
    if (pid <= 0) return;
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

static void wait_cal_mode_cleared(volatile uint32_t *bar1)
{
    uint64_t t0 = now_ns();
    usleep(50000); // 50 ms 确保 bit7 反映
    while ((now_ns() - t0) < 31ULL * 1000000000ULL) {
        if ((rd(bar1, 0x848u) & 0x80u) == 0) {
            break;
        }
        usleep(100000); // 100 ms
    }
}

static void write_osd_text_row(volatile uint32_t *bar1, int row_idx, const char *text)
{
    if (row_idx < 0 || row_idx > 3) return;
    uint32_t base = 0xC00u + (uint32_t)row_idx * 0x40u;
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

static void show_playback_popup(volatile uint32_t *bar1, int sel, int npu, int lane, int view, int zebra)
{
    write_osd_text_row(bar1, 0, "USB PLAY  KEY0 NEXT  KEY1 OK  KEY4 HOLD CLOSE");

    char row1[65];
    memset(row1, ' ', 64);
    row1[64] = '\0';
    row1[0] = (sel == 0) ? '>' : ' ';
    const char *t0 = npu ? "1 NPU:ON" : "1 NPU:OFF";
    memcpy(row1 + 1, t0, strlen(t0));
    row1[20] = (sel == 1) ? '>' : ' ';
    const char *t1 = lane ? "2 LANE:ON" : "2 LANE:OFF";
    memcpy(row1 + 21, t1, strlen(t1));
    write_osd_text_row(bar1, 1, row1);

    char row2[65];
    memset(row2, ' ', 64);
    row2[64] = '\0';
    row2[0] = (sel == 2) ? '>' : ' ';
    const char *t2 = (view == 0) ? "3 VIEW:COLOR" : ((view == 1) ? "3 VIEW:GRAY" : "3 VIEW:BIN");
    memcpy(row2 + 1, t2, strlen(t2));
    row2[18] = (sel == 3) ? '>' : ' ';
    const char *t3 = zebra ? "4 ZEBRA:ON" : "4 ZEBRA:OFF";
    memcpy(row2 + 19, t3, strlen(t3));
    write_osd_text_row(bar1, 2, row2);
}

static void hide_playback_popup(volatile uint32_t *bar1)
{
    write_osd_text_row(bar1, 0, "");
    write_osd_text_row(bar1, 1, "");
    write_osd_text_row(bar1, 2, "");
}

static pid_t start_feed(const char *feed_bin, const char *bar1_str, const char *npu_model_path,
                        char selected_paths[4][1024], int num_selected, int npu)
{
    char video_args[4][1080];
    const char *argv[32];
    int argc = 0;

    argv[argc++] = feed_bin;
    argv[argc++] = "--bar1";
    argv[argc++] = bar1_str;
    argv[argc++] = "--dst";
    argv[argc++] = "960x540";
    argv[argc++] = "--slot0-rgb565";

    for (int s = 0; s < num_selected; s++) {
        snprintf(video_args[s], sizeof(video_args[s]), "%s:%d:30", selected_paths[s], s);
        argv[argc++] = is_still_path(selected_paths[s]) ? "--still" : "--video";
        argv[argc++] = video_args[s];
    }

    if (npu && npu_model_path && npu_model_path[0] != '\0') {
        argv[argc++] = "--npu";
        argv[argc++] = npu_model_path;
    }
    argv[argc++] = "--adas";
    argv[argc++] = "/dev/null";
    /* 4 路 1080p 解码时 CMA 余量紧张：3 路及以上降到 8 个外部缓冲，避免分配失败 */
    argv[argc++] = "--dec-bufs";
    argv[argc++] = (num_selected >= 3) ? "8" : "10";
    argv[argc++] = "--frames";
    argv[argc++] = "0";
    argv[argc] = NULL;

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork usb_feed");
        return -1;
    }
    if (pid == 0) {
        setpgid(0, 0);
        int log_fd = open("/tmp/usb_menu_feed.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (log_fd >= 0) {
            dup2(log_fd, STDOUT_FILENO);
            dup2(log_fd, STDERR_FILENO);
            close(log_fd);
        }
        execvp(feed_bin, (char * const *)argv);
        perror("execvp usb_feed");
        _exit(127);
    }
    setpgid(pid, pid);
    return pid;
}

static int run_playback(volatile uint32_t *bar1,
                        uint32_t fb_base, uint32_t fb_slot,
                        const uint64_t *pas, const size_t *sizes,
                        void **vas,
                        uint32_t *p_seq, uint32_t done_base, uint32_t *p_fid,
                        const char *feed_bin,
                        const char *bar1_str,
                        const char *npu_model_path,
                        char selected_paths[4][1024],
                        int num_selected)
{
    // 1. 先推一帧纯黑到 4 个槽，避免残留 UI
    make_black_frame(vas, sizes);
    if (dma_push_all_slots(bar1, fb_base, fb_slot, pas, sizes, p_seq, done_base, p_fid) < 0) {
        fprintf(stderr, "Failed to push black frame before playback\n");
    }

    // 2. 停掉旧 feed
    system("pkill -x usb_feed 2>/dev/null");

    // 3. 初始状态与寄存器配置
    // 进入播放时默认：NPU 开、LANE 开、VIEW 彩色、ZEBRA 关
    int npu = 1;
    int lane = 1;
    int view = 0;
    int zebra = 0;
    int popup = 0;
    int sel = 0;
    int popup_dirty = 0;

    wr(bar1, 0x880u, 0x30u);
    wr(bar1, 0x800u, (rd(bar1, 0x800u) & ~0x300u) | 0x65u); // VIEW: COLOR
    wr(bar1, 0x8C0u, rd(bar1, 0x8C0u) | 3u);                // LANE 位写 1 (bit0/bit1)
    wr(bar1, 0xA20u, rd(bar1, 0xA20u) & ~1u);               // ZEBRA: 关 (bit0)

    // 清除前 3 行 OSD 文本（避免此前残留）
    hide_playback_popup(bar1);

    // 4. 启动 feed
    pid_t pid = start_feed(feed_bin, bar1_str, npu_model_path, selected_paths, num_selected, npu);
    if (pid < 0) {
        wr(bar1, 0x880u, 0x10u);
        wr(bar1, 0x800u, 0x65u);
        clear_text_ram(bar1);
        clear_all_boxes(bar1);
        return 0;
    }

    // 5. 播放循环
    int exit_app = 0;
    uint32_t last_seq = rd(bar1, 0x844u) & 0xFFu;

    while (1) {
        usleep(30000); // 30 ms

        if (pid <= 0) {
            break;
        }
        int status;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid || (r == -1 && errno == ECHILD)) {
            pid = -1;
            break;
        }

        uint32_t v = rd(bar1, 0x844u);
        uint32_t seq = v & 0xFFu;
        if (seq != last_seq) {
            last_seq = seq;
            uint32_t key = (v >> 8) & 7u;
            uint32_t type = (v >> 12) & 3u;

            if (key == 4 && type == 3) {
                // KEY4 HOLD3：退出整个程序
                kill_pid_gracefully(pid);
                pid = -1;
                wait_cal_mode_cleared(bar1);
                exit_app = 1;
                break;
            } else if (key == 4 && type == 2) {
                // KEY4 长按：弹窗开着 → 只关弹窗；弹窗关着 → 停止播放回列表
                if (popup) {
                    hide_playback_popup(bar1);
                    popup = 0;
                    if (popup_dirty && pid > 0) {
                        kill(pid, SIGUSR1);
                    }
                    popup_dirty = 0;
                } else {
                    kill_pid_gracefully(pid);
                    pid = -1;
                    break;
                }
            } else if (key == 4 && type == 1) {
                // KEY4 短按：弹窗开关
                popup = !popup;
                if (popup) {
                    popup_dirty = 0;
                    show_playback_popup(bar1, sel, npu, lane, view, zebra);
                } else {
                    hide_playback_popup(bar1);
                    if (popup_dirty && pid > 0) {
                        kill(pid, SIGUSR1);
                    }
                    popup_dirty = 0;
                }
            } else if (popup && key == 0 && type == 1) {
                // KEY0：弹窗开着时循环移动标记
                popup_dirty = 1;
                sel = (sel + 1) % 4;
                show_playback_popup(bar1, sel, npu, lane, view, zebra);
            } else if (popup && key == 1 && type == 1) {
                // KEY1：执行对应项动作
                popup_dirty = 1;
                if (sel == 0) {
                    // NPU：取反 → kill 当前 feed → 重启 feed → 刷新文本
                    npu = !npu;
                    kill_pid_gracefully(pid);
                    pid = start_feed(feed_bin, bar1_str, npu_model_path, selected_paths, num_selected, npu);
                    show_playback_popup(bar1, sel, npu, lane, view, zebra);
                } else if (sel == 1) {
                    // LANE：取反 → 0x8C0 bit0/bit1 同时置/清
                    lane = !lane;
                    uint32_t val = rd(bar1, 0x8C0u);
                    if (lane) val |= 3u;
                    else val &= ~3u;
                    wr(bar1, 0x8C0u, val);
                    show_playback_popup(bar1, sel, npu, lane, view, zebra);
                } else if (sel == 2) {
                    // VIEW：(view+1)%3 → 0x800 = (0x800 & ~0x300) | (view<<8)
                    view = (view + 1) % 3;
                    uint32_t val = rd(bar1, 0x800u);
                    val = (val & ~0x300u) | (((uint32_t)view & 3u) << 8);
                    wr(bar1, 0x800u, val);
                    show_playback_popup(bar1, sel, npu, lane, view, zebra);
                } else if (sel == 3) {
                    // ZEBRA：取反 → 0xA20 bit0
                    zebra = !zebra;
                    uint32_t val = rd(bar1, 0xA20u);
                    if (zebra) val |= 1u;
                    else val &= ~1u;
                    wr(bar1, 0xA20u, val);
                    show_playback_popup(bar1, sel, npu, lane, view, zebra);
                }
            }
        }
    }

    if (pid > 0) {
        kill_pid_gracefully(pid);
        pid = -1;
    }

    // 6. 恢复硬件
    wr(bar1, 0x880u, 0x10u);
    wr(bar1, 0x800u, 0x65u);
    clear_text_ram(bar1);
    clear_all_boxes(bar1);

    return exit_app;
}

int main(int argc, char **argv)
{
    uint64_t bar1_addr = 0xf0204000ULL;
    const char *mount_point = "/mnt/usb";
    const char *feed_bin = "/userdata/quad/usb_feed";
    const char *npu_model_path = "/userdata/quad/b5_v6n_band.rknn";
    const char *cjk_path = "/userdata/quad/ui_cjk.bin";
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
        } else if (!strcmp(argv[i], "--mount")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Missing argument for --mount\n");
                return 5;
            }
            mount_point = argv[++i];
        } else if (!strcmp(argv[i], "--feed")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Missing argument for --feed\n");
                return 5;
            }
            feed_bin = argv[++i];
        } else if (!strcmp(argv[i], "--npu-model")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Missing argument for --npu-model\n");
                return 5;
            }
            npu_model_path = argv[++i];
        } else if (!strcmp(argv[i], "--cjk")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Missing argument for --cjk\n");
                return 5;
            }
            cjk_path = argv[++i];
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            return 5;
        }
    }

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

    // 2. 清场与初始化显示控制
    wr(bar1, 0x880u, 0x10u);
    wr(bar1, 0x8C0u, rd(bar1, 0x8C0u) & ~4u);
    wr(bar1, 0x850u, 0);
    clear_text_ram(bar1);
    clear_all_boxes(bar1);
    /* FPGA reset leaves DDR doorbell engine disabled; enable it before any push */
    wr(bar1, 0x1A0u, 1u);
    /* FPGA reset defaults stride=1920/uv=1920*1080; four-slot layout needs 960/518400 */
    wr(bar1, 0x804u, 0x04000000u);
    wr(bar1, 0x808u, 0x00400000u);
    wr(bar1, 0x80Cu, 960u);
    wr(bar1, 0x810u, 960u * 540u);
    wr(bar1, 0x800u, 0x65u);

    // 3. 分配 4 个槽的 CMA DMA 缓冲
    int dma_fds[4] = { -1, -1, -1, -1 };
    void *dma_vas[4] = { NULL, NULL, NULL, NULL };
    uint64_t dma_pas[4] = { 0, 0, 0, 0 };
    for (int i = 0; i < 4; i++) {
        char buf_name[32];
        snprintf(buf_name, sizeof(buf_name), "usb_menu_slot%d", i);
        if (alloc_dma_buf(buf_name, k_tile_sizes[i], &dma_fds[i], &dma_vas[i], &dma_pas[i]) < 0) {
            fprintf(stderr, "Failed to allocate DMA buffer for slot %d\n", i);
            munmap(map, 4096 + page_off);
            close(mem_fd);
            return 1;
        }
    }

    // 4. 分配 1920x1080 RGB888 画布与加载 CJK 字库
    uint8_t *canvas = malloc(SCREEN_W * SCREEN_H * 3);
    if (!canvas) {
        fprintf(stderr, "Failed to allocate canvas memory\n");
        return 1;
    }
    load_cjk_font(&g_cjk_font, cjk_path);

    uint32_t fb_base = rd(bar1, 0x804u);
    if (fb_base == 0) fb_base = 0x04000000u;
    uint32_t fb_slot = rd(bar1, 0x808u);
    if (fb_slot == 0) fb_slot = 0x00400000u;

    uint32_t g_done_base = rd(bar1, 0x1C8u);
    uint32_t g_seq = 0;
    uint32_t fid = 1u;

    // 5. U 盘挂载与目录扫描
    char usb_dev[64] = "";
    int usb_mounted = (scan_and_mount(mount_point, usb_dev, sizeof(usb_dev)) == 0);

    char current_path[1024];
    strncpy(current_path, mount_point, sizeof(current_path) - 1);
    current_path[sizeof(current_path) - 1] = '\0';

    menu_item_t *items = malloc(MAX_ITEMS * sizeof(menu_item_t));
    int total_items = 0;
    int cursor = 0;
    int top_idx = 0;

    char selected_paths[4][1024];
    char selected_names[4][256];
    int num_selected = 0;

    notif_type_t notif_type = NOTIF_NONE;
    uint64_t notif_expiry = 0;

    if (usb_mounted) {
        scan_directory(current_path, mount_point, items, &total_items);
    } else {
        total_items = 0;
    }

    // 画初始界面并推图
    render_ui(canvas, current_path, usb_dev, usb_mounted, items, total_items, cursor, top_idx,
              selected_paths, selected_names, num_selected, notif_type);
    canvas_to_slots(canvas, dma_vas);
    dma_push_all_slots(bar1, fb_base, fb_slot, dma_pas, k_tile_sizes, &g_seq, g_done_base, &fid);

    // 6. 主事件循环
    uint32_t last_seq = rd(bar1, 0x844u) & 0xFFu;
    int exit_code = 0;

    while (1) {
        usleep(30000); // 30 ms

        // 处理临时提示过期
        if (notif_type != NOTIF_NONE && now_ns() >= notif_expiry) {
            notif_type = NOTIF_NONE;
            render_ui(canvas, current_path, usb_dev, usb_mounted, items, total_items, cursor, top_idx,
                      selected_paths, selected_names, num_selected, notif_type);
            canvas_to_slots(canvas, dma_vas);
            dma_push_all_slots(bar1, fb_base, fb_slot, dma_pas, k_tile_sizes, &g_seq, g_done_base, &fid);
        }

        uint32_t v = rd(bar1, 0x844u);
        uint32_t seq = v & 0xFFu;
        if (seq == last_seq) {
            continue;
        }
        last_seq = seq;

        uint32_t key = (v >> 8) & 7u;
        uint32_t type = (v >> 12) & 3u;

        if (key == 4 && type == 3) {
            // HOLD3 KEY4：退出程序
            wait_cal_mode_cleared(bar1);
            exit_code = 0;
            break;
        } else if (key == 4 && type == 2) {
            // 长按 KEY4：退出程序
            exit_code = 0;
            break;
        } else if (key == 4 && type == 1) {
            // 短按 KEY4：返回上一级目录
            if (usb_mounted && strcmp(current_path, mount_point) != 0) {
                char *last_slash = strrchr(current_path, '/');
                if (last_slash && last_slash != current_path) {
                    *last_slash = '\0';
                } else {
                    strncpy(current_path, mount_point, sizeof(current_path) - 1);
                }
                if (strlen(current_path) < strlen(mount_point)) {
                    strncpy(current_path, mount_point, sizeof(current_path) - 1);
                }
                scan_directory(current_path, mount_point, items, &total_items);
                cursor = 0;
                top_idx = 0;

                render_ui(canvas, current_path, usb_dev, usb_mounted, items, total_items, cursor, top_idx,
                          selected_paths, selected_names, num_selected, notif_type);
                canvas_to_slots(canvas, dma_vas);
                dma_push_all_slots(bar1, fb_base, fb_slot, dma_pas, k_tile_sizes, &g_seq, g_done_base, &fid);
            }
            continue;
        }

        if (type == 1 && key == 0) {
            // 短按 KEY0：光标下移（循环，含 START）
            if (total_items > 0) {
                cursor = (cursor + 1) % total_items;
                if (cursor < top_idx) {
                    top_idx = cursor;
                } else if (cursor >= top_idx + MAX_VISIBLE_ROWS) {
                    top_idx = cursor - (MAX_VISIBLE_ROWS - 1);
                }
                render_ui(canvas, current_path, usb_dev, usb_mounted, items, total_items, cursor, top_idx,
                          selected_paths, selected_names, num_selected, notif_type);
                canvas_to_slots(canvas, dma_vas);
                dma_push_all_slots(bar1, fb_base, fb_slot, dma_pas, k_tile_sizes, &g_seq, g_done_base, &fid);
            }
            continue;
        }

        if (type == 1 && key == 1) {
            // 短按 KEY1
            if (!usb_mounted) {
                // 重新尝试挂载
                if (scan_and_mount(mount_point, usb_dev, sizeof(usb_dev)) == 0) {
                    usb_mounted = 1;
                    strncpy(current_path, mount_point, sizeof(current_path) - 1);
                    scan_directory(current_path, mount_point, items, &total_items);
                    cursor = 0;
                    top_idx = 0;
                }
                render_ui(canvas, current_path, usb_dev, usb_mounted, items, total_items, cursor, top_idx,
                          selected_paths, selected_names, num_selected, notif_type);
                canvas_to_slots(canvas, dma_vas);
                dma_push_all_slots(bar1, fb_base, fb_slot, dma_pas, k_tile_sizes, &g_seq, g_done_base, &fid);
                continue;
            }

            if (cursor >= 0 && cursor < total_items) {
                menu_item_t *cur_item = &items[cursor];

                if (cur_item->type == ITEM_DIR_UP) {
                    char *last_slash = strrchr(current_path, '/');
                    if (last_slash && last_slash != current_path) {
                        *last_slash = '\0';
                    } else {
                        strncpy(current_path, mount_point, sizeof(current_path) - 1);
                    }
                    if (strlen(current_path) < strlen(mount_point)) {
                        strncpy(current_path, mount_point, sizeof(current_path) - 1);
                    }
                    scan_directory(current_path, mount_point, items, &total_items);
                    cursor = 0;
                    top_idx = 0;
                } else if (cur_item->type == ITEM_DIR) {
                    char next_path[1024];
                    snprintf(next_path, sizeof(next_path), "%s/%s", current_path, cur_item->name);
                    strncpy(current_path, next_path, sizeof(current_path) - 1);
                    scan_directory(current_path, mount_point, items, &total_items);
                    cursor = 0;
                    top_idx = 0;
                } else if (cur_item->type == ITEM_FILE) {
                    int s_idx = get_selection_index(cur_item->full_path, selected_paths, num_selected);
                    if (s_idx >= 0) {
                        // 移出已选，后续项前移
                        for (int k = s_idx; k < num_selected - 1; k++) {
                            strcpy(selected_paths[k], selected_paths[k + 1]);
                            strcpy(selected_names[k], selected_names[k + 1]);
                        }
                        num_selected--;
                    } else {
                        if (num_selected >= 4) {
                            notif_type = NOTIF_MAX_VIDEOS;
                            notif_expiry = now_ns() + 2ULL * 1000000000ULL;
                        } else {
                            struct stat st;
                            if (stat(cur_item->full_path, &st) != 0) {
                                // 文件丢失，重新扫目录
                                scan_directory(current_path, mount_point, items, &total_items);
                            } else {
                                strncpy(selected_paths[num_selected], cur_item->full_path, sizeof(selected_paths[0]) - 1);
                                strncpy(selected_names[num_selected], cur_item->name, sizeof(selected_names[0]) - 1);
                                num_selected++;
                            }
                        }
                    }
                } else if (cur_item->type == ITEM_START) {
                    if (num_selected >= 1) {
                        // 校验已选文件是否仍然存在
                        for (int s = 0; s < num_selected; ) {
                            struct stat st;
                            if (stat(selected_paths[s], &st) != 0) {
                                for (int k = s; k < num_selected - 1; k++) {
                                    strcpy(selected_paths[k], selected_paths[k + 1]);
                                    strcpy(selected_names[k], selected_names[k + 1]);
                                }
                                num_selected--;
                            } else {
                                s++;
                            }
                        }

                        if (num_selected >= 1) {
                            int exit_app = run_playback(bar1, fb_base, fb_slot, dma_pas, k_tile_sizes,
                                                        dma_vas, &g_seq, g_done_base, &fid,
                                                        feed_bin, bar1_str_buf, npu_model_path,
                                                        selected_paths, num_selected);
                            if (exit_app) {
                                exit_code = 0;
                                break;
                            }
                            last_seq = rd(bar1, 0x844u) & 0xFFu;
                        }
                    }
                }

                render_ui(canvas, current_path, usb_dev, usb_mounted, items, total_items, cursor, top_idx,
                          selected_paths, selected_names, num_selected, notif_type);
                canvas_to_slots(canvas, dma_vas);
                dma_push_all_slots(bar1, fb_base, fb_slot, dma_pas, k_tile_sizes, &g_seq, g_done_base, &fid);
            }
            continue;
        }
    }

    // 7. 退出前卸载挂载点与释放资源
    if (usb_mounted) {
        unmount_usb(mount_point);
    }

    free(canvas);
    free(items);
    free_cjk_font(&g_cjk_font);

    for (int i = 0; i < 4; i++) {
        if (dma_vas[i] && dma_vas[i] != MAP_FAILED) {
            size_t alloc_len = (k_tile_sizes[i] + 4095u) & ~(size_t)4095u;
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
