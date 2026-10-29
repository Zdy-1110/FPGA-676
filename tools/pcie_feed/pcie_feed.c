/*
 * pcie_feed — RK3568 上通过 PCIe 门铃 DMA 向 FPGA 显示通路送 NV12 帧
 *             （无 libc、32 位 ARM、原始系统调用）。
 *
 * 用途：在没有 aarch64 交叉编译环境时，把本地 NV12 帧经 PCIe 写入 FPGA 的 DDR3
 *       显示槽并提交，用于验证 disp1 比特流的显示通路（送静态帧或连续流）。
 *
 * 用法：pcie_feed <bar1_hex> <cmd> [参数]
 *   regs                                   打印 0x800-0x84C 与 0x1C0-0x1EC
 *   get <off_hex>                          读任意 BAR1 偏移
 *   set <off_hex> <val_hex>                写任意 BAR1 偏移并回读打印
 *   pat                                    DISP_CTRL=0x6 后打印 regs
 *   still <file> <stride_dec> [ctrl_hex]   送一帧到槽 0 并提交（ctrl 缺省 0x5）
 *   stream <file|-> <stride_dec> [ctrl_hex] [loop]
 *                                          连续送帧，槽轮转 (n+1)%4，"-"=stdin
 *
 * 编译（PC，Git Bash）：
 *   "/d/Program Files/STM32CubeCLT_1.20.0/st-arm-clang/bin/starm-clang" \
 *     --target=armv7a-linux-gnueabihf -marm -O2 -ffreestanding -fno-builtin \
 *     -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables \
 *     -nostdlib -nostdinc -c pcie_feed.c -o pcie_feed.o
 *   "/d/Program Files/STM32CubeCLT_1.20.0/st-arm-clang/bin/ld.lld" \
 *     -static -e _start --build-id=none -z norelro pcie_feed.o -o pcie_feed
 *
 * 前提：
 *   - EP 已使能 MEM/BME（echo 1 > .../enable）。
 *   - 已加载 disp1 比特流：0x188=0x4D524432, 0x1E8=0x44445231, 0x83C=0x44535031。
 *   - 已用 ramoops:pmsg 保留区（0x001b0000-0x001fffff，320KB）做 DMA 中转区。
 *
 * NV12 帧布局：Y plane stride*1080 字节，紧跟 UV plane stride*540 字节，
 *             共 stride*1620 字节；stride 可为 1920 或 2304。
 */
typedef unsigned int u32;
typedef unsigned long long u64;

/* ---------- raw syscalls (ARM EABI) ---------- */
static inline long sc(long n, long a, long b, long c, long d, long e, long f)
{
    register long r0 __asm__("r0") = a;
    register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c;
    register long r3 __asm__("r3") = d;
    register long r4 __asm__("r4") = e;
    register long r5 __asm__("r5") = f;
    register long r7 __asm__("r7") = n;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r5), "r"(r7) : "memory");
    return r0;
}
#define SYS_read 3
#define SYS_write 4
#define SYS_open 5
#define SYS_close 6
#define SYS_lseek 19
#define SYS_nanosleep 162
#define SYS_clock_gettime 263
#define SYS_mmap2 192
#define SYS_exit_group 248
#define SYS_sched_setaffinity 241

struct ts32 { long sec; long nsec; };

static u64 now_ns(void)
{
    struct ts32 t;
    sc(SYS_clock_gettime, 1 /*CLOCK_MONOTONIC*/, (long)&t, 0, 0, 0, 0);
    return (u64)(u32)t.sec * 1000000000ULL + (u32)t.nsec;
}

static void sleep_ms(u32 ms)
{
    struct ts32 t;
    t.sec = (long)(ms / 1000u);
    t.nsec = (long)(ms % 1000u) * 1000000L;
    sc(SYS_nanosleep, (long)&t, 0, 0, 0, 0, 0);
}

/* ---------- tiny helpers (no libc) ---------- */
static u64 udiv64(u64 n, u64 d)
{
    u64 q = 0, r = 0;
    int i;
    if (!d) return 0;
    for (i = 63; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) { r -= d; q |= 1ULL << i; }
    }
    return q;
}

static void out(const char *s) { unsigned n = 0; while (s[n]) n++; sc(SYS_write, 1, (long)s, n, 0, 0, 0); }
static void outu(u64 v)
{
    char b[24]; int i = 23; b[i] = 0;
    if (!v) b[--i] = '0';
    while (v) { u64 q = udiv64(v, 10); b[--i] = (char)('0' + (unsigned)(v - q * 10)); v = q; }
    out(b + i);
}
/* v10 = value*10 → "x.y" */
static void outf1(u64 v10) { u64 ip = udiv64(v10, 10); outu(ip); out("."); outu(v10 - ip * 10); }
static void outhex(u32 v)
{
    const char *h = "0123456789abcdef"; char b[11]; int i;
    b[0] = '0'; b[1] = 'x';
    for (i = 0; i < 8; i++) b[2 + i] = h[(v >> (28 - 4 * i)) & 15];
    b[10] = 0; out(b);
}
static u32 parse_hex(const char *s)
{
    u32 v = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    while (*s) {
        char c = *s++; v <<= 4;
        if (c >= '0' && c <= '9') v |= (u32)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (u32)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (u32)(c - 'A' + 10);
    }
    return v;
}
static u32 parse_dec(const char *s) { u32 v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (u32)(*s++ - '0'); return v; }
static int eq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }

/* ---------- device ---------- */
static volatile u32 *regs;    /* BAR1 */
static unsigned char *relay;  /* DMA 中转区（ramoops:pmsg 320KB） */

static inline void wr(u32 off, u32 v) { regs[off >> 2] = v; }
static inline u32 rd(u32 off) { return regs[off >> 2]; }

#define RELAY_PHYS 0x001b0000u   /* 中转区物理基址 */
#define HALF_SZ    0x28000u      /* A/B 半区各 160KB */
#define RELAY_SZ   0x50000u      /* 320KB */

/* disp1 显示寄存器 */
#define R_DISP_CTRL  0x800u
#define R_FB_BASE    0x804u
#define R_FB_SLOT    0x808u
#define R_FB_STRIDE  0x80Cu
#define R_FB_UVOFF   0x810u
#define R_FB_COMMIT  0x814u
#define R_DISP_NEWFR 0x828u
#define R_DISP_UF    0x82Cu

static long g_fd = -1;           /* 输入 fd，0=stdin */
static u32 g_seq;                /* 本进程已入队门铃序号 */
static u32 g_done_base;          /* 起始 0x1C8 计数（假定队列已排空） */
static u32 g_pend_valid[2];      /* 每个半区是否有未完成门铃 */
static u32 g_pend_seq[2];        /* 该半区未完成门铃的序号 */
static u64 g_read_ns, g_dma_ns;  /* 累计 read / 等门铃耗时 */

static void die(int code, const char *msg)
{
    if (msg) { out("!! "); out(msg); out("\n"); }
    sc(SYS_exit_group, (long)code, 0, 0, 0, 0, 0);
    for (;;) {}
}

static void dump_range(u32 from, u32 to)
{
    u32 o;
    for (o = from; o <= to; o += 4u) { outhex(o); out("="); outhex(rd(o)); out("\n"); }
}

/* 门铃超时：打印 DDR 与显示核心寄存器后退出码 3 */
static void dump_fail(void)
{
    out("!! doorbell timeout\n");
    dump_range(0x1C0, 0x1EC);
    dump_range(0x800, 0x830);
    die(3, 0);
}

static void wait_count(u32 target)
{
    u64 t0 = now_ns();
    for (;;) {
        if (rd(0x1C8) >= target) { g_dma_ns += now_ns() - t0; return; }
        if (now_ns() - t0 >= 2000000000ULL) dump_fail();
    }
}

static void wait_half(u32 half)
{
    if (g_pend_valid[half]) {
        wait_count(g_done_base + g_pend_seq[half]);
        g_pend_valid[half] = 0;
    }
}

static void db_push(u32 host, u32 bytes, u32 dst, u32 id)
{
    wr(0x190, host); wr(0x194, bytes); wr(0x198, dst); wr(0x19C, id);
}

/* 循环 read 直到读满 len 或到文件尾，返回实际读到的字节数 */
static u32 read_into(unsigned char *dst, u32 len)
{
    u32 got = 0;
    while (got < len) {
        long r = sc(SYS_read, g_fd, (long)(dst + got), (long)(len - got), 0, 0, 0);
        if (r <= 0) break;
        got += (u32)r;
    }
    return got;
}

/* 送一帧：以 160KB 分块，A/B 交替，块间等待对应半区上次门铃完成；
   全部块完成后再由调用者写 FB_COMMIT。返回实际读入字节数（0=帧首即 EOF）。 */
static u32 feed_frame(u32 slot, u32 base, u32 slot_size, u32 frame_sz)
{
    u32 slot_start = base + slot * slot_size;
    u32 remaining = frame_sz, k = 0, total = 0;
    while (remaining) {
        u32 blen = remaining > HALF_SZ ? HALF_SZ : remaining;
        u32 half = k & 1u, n;
        unsigned char *hp = relay + (u32)half * HALF_SZ;
        wait_half(half);
        {
            u64 t0 = now_ns();
            n = read_into(hp, blen);
            g_read_ns += now_ns() - t0;
        }
        if (!n) break;                                   /* 文件尾 */
        if (n & 255u) die(4, "block length not multiple of 256");
        g_seq++;
        db_push(RELAY_PHYS + half * HALF_SZ, n, slot_start + k * HALF_SZ, g_seq);
        g_pend_valid[half] = 1; g_pend_seq[half] = g_seq;
        total += n; remaining -= blen; k++;
        if (n < blen) break;                             /* 末块不足 */
    }
    wait_half(0); wait_half(1);
    return total;
}

static void check_magic(void)
{
    u32 a = rd(0x188), b = rd(0x1E8), c = rd(0x83C);
    if (a != 0x4D524432u || b != 0x44445231u || (c != 0x44535031u && c != 0x4F534431u)) {   /* DSP1 或 OSD1 */
        out("!! magic mismatch\n");
        out("  0x188="); outhex(a); out(" 0x1E8="); outhex(b); out(" 0x83C="); outhex(c); out("\n");
        die(7, 0);
    }
}

static void open_input(const char *f)
{
    if (f[0] == '-' && f[1] == 0) { g_fd = 0; return; }
    g_fd = sc(SYS_open, (long)f, 0 /*O_RDONLY*/, 0, 0, 0, 0);
    if (g_fd < 0) die(1, "open input failed");
}

/* ---------- commands ---------- */
static int cmd_regs(void) { dump_range(0x800, 0x84C); dump_range(0x1C0, 0x1EC); return 0; }

static int cmd_get(int argc, char **argv)
{
    u32 o;
    if (argc < 4) return 2;
    o = parse_hex(argv[3]);
    outhex(o); out("="); outhex(rd(o)); out("\n");
    return 0;
}

static int cmd_set(int argc, char **argv)
{
    u32 o, v;
    if (argc < 5) return 2;
    o = parse_hex(argv[3]); v = parse_hex(argv[4]);
    wr(o, v);
    outhex(o); out("="); outhex(rd(o)); out("\n");
    return 0;
}

static int cmd_pat(void) { wr(R_DISP_CTRL, 0x6); return cmd_regs(); }

static void progress(u32 ndone, u64 t_start)
{
    u64 el = now_ns() - t_start;
    u64 npf = ndone ? udiv64(el, (u64)ndone) : 0;   /* 每帧平均纳秒 */
    out("frame="); outu(ndone);
    out(" fps="); if (npf) outf1(udiv64(10000000000ULL, npf)); else out("-");
    out(" read_ms="); outu(udiv64(g_read_ns, 1000000ULL));
    out(" dma_ms="); outu(udiv64(g_dma_ns, 1000000ULL));
    out(" newfr="); outu(rd(R_DISP_NEWFR));
    out(" underflow="); outu(rd(R_DISP_UF));
    out("\n");
}

static int cmd_still(int argc, char **argv)
{
    const char *file, *ss;
    u32 stride, ctrl, frame_sz, base, slot_size, got;

    if (argc < 5) return 2;
    file = argv[3]; ss = argv[4];
    stride = parse_dec(ss);
    if (!stride) die(2, "bad stride");
    ctrl = (argc > 5) ? parse_hex(argv[5]) : 0x5u;

    check_magic();
    open_input(file);

    frame_sz = stride * 1620u;
    wr(0x1A0, 1);                                   /* DDR 使能 */
    base = rd(R_FB_BASE);
    slot_size = rd(R_FB_SLOT);
    got = feed_frame(0, base, slot_size, frame_sz);
    if (got != frame_sz) {
        out("!! short frame got="); outu(got); out(" want="); outu(frame_sz); out("\n");
        return 4;
    }
    wr(R_FB_STRIDE, stride);
    wr(R_FB_UVOFF, stride * 1080u);
    wr(R_DISP_CTRL, ctrl);
    wr(R_FB_COMMIT, (1u << 16) | 0u);               /* frame_id=1, slot=0 */
    sleep_ms(100);
    return cmd_regs();
}

static int cmd_stream(int argc, char **argv)
{
    const char *file, *ss;
    u32 stride, ctrl, frame_sz, base, slot_size;
    int loop;
    u64 t_start;
    u32 n = 0, ndone = 0, next_print = 30;

    if (argc < 5) return 2;
    file = argv[3]; ss = argv[4];
    stride = parse_dec(ss);
    if (!stride) die(2, "bad stride");
    ctrl = (argc > 5) ? parse_hex(argv[5]) : 0x5u;
    loop = (argc > 6) ? 1 : 0;

    check_magic();
    open_input(file);

    frame_sz = stride * 1620u;
    wr(0x1A0, 1);                                   /* DDR 使能 */
    wr(R_FB_STRIDE, stride);
    wr(R_FB_UVOFF, stride * 1080u);
    wr(R_DISP_CTRL, ctrl);
    base = rd(R_FB_BASE);
    slot_size = rd(R_FB_SLOT);

    t_start = now_ns();
    for (;;) {
        u32 slot = (n + 1u) & 3u;                   /* (n+1)%4 */
        u32 got = feed_frame(slot, base, slot_size, frame_sz);
        if (got) {
            wr(R_FB_COMMIT, (((n + 1u) & 0xFFFFu) << 16) | slot);
            ndone++; n++;
            if (ndone == next_print) { progress(ndone, t_start); next_print += 30u; }
            if (got == frame_sz) continue;          /* 完整帧，继续下一帧 */
        }
        /* got==0：帧首 EOF；或 got<frame_sz：末帧不足 */
        if (loop && g_fd > 0) { sc(SYS_lseek, g_fd, 0, 0, 0, 0, 0); continue; }
        break;
    }
    if (ndone && (ndone % 30u)) progress(ndone, t_start);
    return 0;
}

static void usage(void)
{
    out("usage: pcie_feed <bar1_hex> <cmd> [args]\n");
    out("  regs\n");
    out("  get <off_hex>\n");
    out("  set <off_hex> <val_hex>\n");
    out("  pat\n");
    out("  still <file> <stride_dec> [ctrl_hex]\n");
    out("  stream <file|-> <stride_dec> [ctrl_hex] [loop]\n");
}

static void *map(int fd, u32 phys, u32 len)
{
    long r = sc(SYS_mmap2, 0, len, 3 /*RW*/, 1 /*SHARED*/, fd, phys >> 12);
    if (r < 0 && r > -4096) {
        out("!! mmap failed phys="); outhex(phys); out(" err="); outu((u64)(-r)); out("\n");
        die(2, 0);
    }
    return (void *)r;
}

int cmain(u32 *sp)
{
    u32 argc = sp[0];
    char **argv = (char **)(sp + 1);
    u32 bar1 = 0xf0204000u;
    u32 mask = 1u << 3;   /* pin to CPU3 */
    long fd;
    int ac = (int)argc;
    const char *cmd;

    if (argc < 3) { usage(); return 2; }
    bar1 = parse_hex(argv[1]);
    sc(SYS_sched_setaffinity, 0, 4, (long)&mask, 0, 0, 0);

    fd = sc(SYS_open, (long)"/dev/mem", 0x101002 /*O_RDWR|O_SYNC*/, 0, 0, 0, 0);
    if (fd < 0) { out("!! open /dev/mem failed\n"); return 1; }
    regs = (volatile u32 *)map((int)fd, bar1, 0x1000);
    relay = (unsigned char *)map((int)fd, RELAY_PHYS, RELAY_SZ);

    /* 等队列排空后取 0x1C8 基准，避免把上一次遗留门铃算进本进程的 target */
    {
        int i; u32 v = rd(0x1C8);
        for (i = 0; i < 200; i++) {
            u32 w;
            sleep_ms(5);
            w = rd(0x1C8);
            if (w == v) break;
            v = w;
        }
        g_done_base = v;
    }

    cmd = argv[2];
    if (eq(cmd, "regs")) return cmd_regs();
    if (eq(cmd, "get")) return cmd_get(ac, argv);
    if (eq(cmd, "set")) return cmd_set(ac, argv);
    if (eq(cmd, "pat")) return cmd_pat();
    if (eq(cmd, "still")) return cmd_still(ac, argv);
    if (eq(cmd, "stream")) return cmd_stream(ac, argv);

    usage();
    return 2;
}

__asm__(".text\n.global _start\n_start:\n mov r0, sp\n bl cmain\n mov r7, #248\n svc 0\n");
