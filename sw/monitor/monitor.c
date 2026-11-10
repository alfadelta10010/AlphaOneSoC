/* AlphaOne monitor (ROADMAP 9.2, rung 3): a prompt on the UART that reports
 * the contents of any register or memory location.
 *
 *   r [reg [val]]        the 31 registers and pc of the stopped program; one, or set one
 *   csr [num|name [val]] every CSR the core has; read or write one by name or number
 *   csr scan [lo hi]     try every CSR number, list the ones that exist
 *   m[b|h|w] addr [n]    dump n bytes, halfwords or words (default 16 words)
 *   w[b|h|w] addr val    write one
 *   p                    the peripheral registers: CLINT, UART, GPIO/SPI, syscon
 *   i                    ids, ISA, counters, reset cause
 *   g addr, gb addr      run a program (gb: Ctrl-C stops it and shows where it was)
 *   x                    carry on with the stopped program
 *   q                    end the run (syscon power-off)
 *
 * Numbers are hexadecimal. A program stops on ebreak, on any trap, when it
 * returns, or at Ctrl-C under gb. A read of an address nothing answers
 * faults and prints "fault". The monitor owns mscratch (the program's
 * registers are saved through it), so a program under it must not use that
 * CSR, and under gb it must leave the UART receiver alone (the monitor
 * looks for Ctrl-C every TICK clocks and takes the byte). */
#include <stdio.h>
#include <string.h>
#include "soc.h"

struct frame {
    uint32_t x[32];
    uint32_t mepc, mstatus, mcause, mtval;
};

#define TICK       625000u          /* clocks between Ctrl-C checks: 10 ms at 62.5 MHz */
#define MIE_MTIE   0x80u
#define ST_MPIE    0x80u
#define ST_MPP_M   0x1800u

extern uint32_t _stack_top;
extern uint32_t mon_probe_resume;
extern void mon_trap_entry(void), mon_return(void), mon_resume(struct frame *) __attribute__((noreturn));
extern void mon_switch_stack(void *sp, void (*fn)(void)) __attribute__((noreturn));
extern void mon_lw(void), mon_lh(void), mon_lb(void), mon_sw(void), mon_sh(void), mon_sb(void);
extern void demo_regs(void), demo_spin(void);
extern int  mon_probe(void *fn, uint32_t a0, uint32_t a1, uint32_t *out);

static uint32_t mon_stack[2048] __attribute__((aligned(16)));
#define FRAME ((struct frame *)((uintptr_t)&mon_stack[2048] - sizeof(struct frame)))

static int ctx_valid;               /* a program has stopped and its registers are in FRAME */
static int break_in;                /* the program runs with the Ctrl-C check */

static const char *const rname[32] = {
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
};

static const struct { const char *name; uint16_t num; } csrs[] = {
    {"mvendorid", 0xF11}, {"marchid", 0xF12}, {"mimpid", 0xF13}, {"mhartid", 0xF14}, {"mconfigptr", 0xF15},
    {"mstatus", 0x300}, {"misa", 0x301}, {"mie", 0x304}, {"mtvec", 0x305}, {"mcounteren", 0x306},
    {"mcountinhibit", 0x320}, {"mscratch", 0x340}, {"mepc", 0x341}, {"mcause", 0x342}, {"mtval", 0x343},
    {"mip", 0x344}, {"pmpcfg0", 0x3A0}, {"pmpaddr0", 0x3B0}, {"pmpaddr1", 0x3B1}, {"pmpaddr2", 0x3B2},
    {"pmpaddr3", 0x3B3}, {"mcycle", 0xB00}, {"mcycleh", 0xB80}, {"minstret", 0xB02}, {"minstreth", 0xB82},
    {"mstatush", 0x310}, {"menvcfg", 0x30A}, {"cycle", 0xC00}, {"cycleh", 0xC80}, {"time", 0xC01}, {"timeh", 0xC81}, {"instret", 0xC02},
    {"instreth", 0xC82},
};
#define NCSR (sizeof csrs / sizeof csrs[0])

static const char *const cause_name[16] = {
    "instruction address misaligned", "instruction access fault", "illegal instruction", "breakpoint",
    "load address misaligned", "load access fault", "store address misaligned", "store access fault",
    "ecall from U", "ecall from S", "reserved", "ecall from M", "page fault", "page fault", "reserved", "page fault"
};

/* ── memory access that reports a fault ──────────────────────────────────── */
static int rd(char sz, uint32_t a, uint32_t *v)
{
    return mon_probe(sz == 'b' ? (void *)mon_lb : sz == 'h' ? (void *)mon_lh : (void *)mon_lw, a, 0, v);
}

static int wr(char sz, uint32_t a, uint32_t val)
{
    uint32_t dummy;
    return mon_probe(sz == 'b' ? (void *)mon_sb : sz == 'h' ? (void *)mon_sh : (void *)mon_sw, a, val, &dummy);
}

/* CSRs are numbers in the instruction, so a stub is made in RAM:
 * csrrs a0,N,x0 or csrrw x0,N,a0, then ret. A number the core lacks traps. */
static volatile uint32_t stub[2] __attribute__((aligned(4)));

static void make_stub(uint32_t n, int write)
{
    stub[0] = write ? (n << 20) | (10u << 15) | (1u << 12) | 0x73u
                    : (n << 20) | (2u << 12) | (10u << 7) | 0x73u;
    stub[1] = 0x00008067u;
    __asm__ volatile("fence.i" ::: "memory");
}

static int csr_read(uint32_t n, uint32_t *v)
{
    make_stub(n, 0);
    return mon_probe((void *)stub, 0, 0, v);
}

static int csr_write(uint32_t n, uint32_t val)
{
    uint32_t dummy;
    make_stub(n, 1);
    return mon_probe((void *)stub, val, 0, &dummy);
}

/* ── the timer tick that looks for Ctrl-C ────────────────────────────────── */
static void set_mtimecmp(uint64_t t)
{
    *reg32(CLINT_MTIMECMP + 4) = 0xFFFFFFFFu;       /* no spurious match in between */
    *reg32(CLINT_MTIMECMP) = (uint32_t)t;
    *reg32(CLINT_MTIMECMP + 4) = (uint32_t)(t >> 32);
}

static void tick_on(void)
{
    set_mtimecmp(mtime_read() + TICK);
    __asm__ volatile("csrs mie, %0" :: "r"(MIE_MTIE));
}

static void tick_off(void)
{
    __asm__ volatile("csrc mie, %0" :: "r"(MIE_MTIE));
    set_mtimecmp(~0ull);
}

/* ── input ───────────────────────────────────────────────────────────────── */
static int getline(char *buf, int max)
{
    int n = 0;
    for (;;) {
        int c = uart_getc();
        if (c == '\r' || c == '\n') {
            uart_puts("\n");
            buf[n] = 0;
            return n;
        }
        if ((c == 8 || c == 127) && n) {
            n--;
            uart_puts("\b \b");
        } else if (c >= ' ' && c < 127 && n < max - 1) {
            buf[n++] = c;
            uart_putc(c);
        }
    }
}

static int hexval(int c)
{
    return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
}

static int parse_hex(const char *s, uint32_t *v)
{
    uint32_t r = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        s += 2;
    if (hexval(*s) < 0)
        return 0;
    for (; hexval(*s) >= 0; s++)
        r = (r << 4) | hexval(*s);
    *v = r;
    return *s == 0;
}

/* ── the commands ────────────────────────────────────────────────────────── */
static void show_stop(const struct frame *f)
{
    uint32_t c = f->mcause;
    if (c & 0x80000000u)
        printf("interrupt %u", c & 0x7FFFFFFFu);
    else
        printf("%s", c < 16 ? cause_name[c] : "?");
    printf(" at pc=%08x (mcause=%08x mtval=%08x)\n", f->mepc, c, f->mtval);
}

static int reg_index(const char *s)
{
    if (!strcmp(s, "fp"))
        return 8;
    for (int i = 0; i < 32; i++)
        if (!strcmp(s, rname[i]))
            return i;
    if (s[0] == 'x' && s[1]) {
        uint32_t n = 0;
        for (const char *p = s + 1; *p; p++) {
            if (*p < '0' || *p > '9')
                return -1;
            n = n * 10 + (*p - '0');
        }
        return n < 32 ? (int)n : -1;
    }
    return -1;
}

static void cmd_r(struct frame *f, int ac, char **av)
{
    if (!ctx_valid) {
        puts("no stopped program: run one with g or gb (demo_regs, demo_spin), or it stops at ebreak");
        return;
    }
    if (ac == 1) {
        for (int i = 0; i < 32; i += 4)
            printf("%-4s %08x  %-4s %08x  %-4s %08x  %-4s %08x\n",
                   rname[i], f->x[i], rname[i + 1], f->x[i + 1], rname[i + 2], f->x[i + 2], rname[i + 3], f->x[i + 3]);
        printf("pc   %08x  mstatus %08x  mcause %08x  mtval %08x\n", f->mepc, f->mstatus, f->mcause, f->mtval);
        return;
    }
    uint32_t *slot;
    int i = reg_index(av[1]);
    if (i >= 0)
        slot = &f->x[i];
    else if (!strcmp(av[1], "pc"))
        slot = &f->mepc;
    else {
        printf("no register %s\n", av[1]);
        return;
    }
    if (ac == 2) {
        printf("%s = %08x\n", av[1], *slot);
        return;
    }
    uint32_t v;
    if (!parse_hex(av[2], &v) || slot == &f->x[0]) {
        puts("bad value, or x0");
        return;
    }
    *slot = v;
    printf("%s = %08x\n", av[1], v);
}

static int csr_lookup(const char *s, uint32_t *num)
{
    for (unsigned i = 0; i < NCSR; i++)
        if (!strcmp(s, csrs[i].name)) {
            *num = csrs[i].num;
            return 1;
        }
    return parse_hex(s, num) && *num < 0x1000;
}

static const char *csr_name(uint32_t n)
{
    for (unsigned i = 0; i < NCSR; i++)
        if (csrs[i].num == n)
            return csrs[i].name;
    return "";
}

static void cmd_csr(int ac, char **av)
{
    uint32_t n, v;
    if (ac >= 2 && !strcmp(av[1], "scan")) {
        uint32_t lo = 0, hi = 0xFFF;
        if (ac > 2 && !parse_hex(av[2], &lo))
            return;
        if (ac > 3 && !parse_hex(av[3], &hi))
            return;
        for (n = lo; n <= hi && n < 0x1000; n++)
            if (!csr_read(n, &v))
                printf("%03x %-13s %08x\n", n, csr_name(n), v);
        puts("scan done");
        return;
    }
    if (ac == 1) {
        for (unsigned i = 0; i < NCSR; i++)
            if (!csr_read(csrs[i].num, &v))
                printf("%03x %-13s %08x\n", csrs[i].num, csrs[i].name, v);
        puts("(mscratch reads 0: the monitor owns it. Live values, not the stopped program's: r shows those)");
        return;
    }
    if (!csr_lookup(av[1], &n)) {
        printf("no CSR %s\n", av[1]);
        return;
    }
    if (ac >= 3) {
        if (!parse_hex(av[2], &v)) {
            puts("bad value");
            return;
        }
        if (csr_write(n, v)) {
            puts("fault (read-only or absent)");
            return;
        }
    }
    if (csr_read(n, &v))
        printf("%03x fault (no such CSR)\n", n);
    else
        printf("%03x %-13s %08x\n", n, csr_name(n), v);
}

/* "fault" in the width of the value it stands for */
static void put_fault(int w)
{
    uart_puts("fault");
    for (int i = 5; i < 2 * w; i++)
        uart_putc(' ');
}

static void cmd_m(char sz, int ac, char **av)
{
    uint32_t a, n, v;
    int w = sz == 'b' ? 1 : sz == 'h' ? 2 : 4;
    if (ac < 2 || !parse_hex(av[1], &a)) {
        puts("m[b|h|w] addr [count]");
        return;
    }
    n = sz == 'b' ? 64 : sz == 'h' ? 32 : 16;
    if (ac > 2 && !parse_hex(av[2], &n))
        return;
    int per = 16 / w;
    while (n) {
        uint8_t asc[16];
        int k;
        printf("%08x:", a);
        for (k = 0; k < per && n; k++, n--, a += w) {
            uart_putc(' ');
            if (rd(sz, a, &v)) {
                put_fault(w);
                v = 0x2E2E2E2Eu;
            } else {
                uart_puthex(v, 2 * w);
            }
            for (int j = 0; j < w; j++)
                asc[k * w + j] = (v >> (8 * j)) & 0xFF;
        }
        uart_puts("  |");
        for (int j = 0; j < k * w; j++)
            uart_putc(asc[j] >= ' ' && asc[j] < 127 ? asc[j] : '.');
        uart_puts("|\n");
    }
}

static void cmd_w(char sz, int ac, char **av)
{
    uint32_t a, v;
    if (ac < 3 || !parse_hex(av[1], &a) || !parse_hex(av[2], &v)) {
        puts("w[b|h|w] addr value");
        return;
    }
    if ((sz == 'h' && (a & 1)) || (sz == 'w' && (a & 3))) {
        puts("misaligned");
        return;
    }
    if (wr(sz, a, v))
        puts("fault");
}

/* One register: print its name and value, or fault. */
static void preg(const char *name, char sz, uint32_t a)
{
    uint32_t v;
    printf("  %08x %-16s ", a, name);
    if (rd(sz, a, &v))
        puts("fault");
    else {
        uart_puthex(v, sz == 'b' ? 2 : 8);
        uart_puts("\n");
    }
}

static void cmd_p(void)
{
    puts("CLINT");
    preg("msip", 'w', 0x02000000);
    preg("mtimecmp lo", 'w', CLINT_MTIMECMP);
    preg("mtimecmp hi", 'w', CLINT_MTIMECMP + 4);
    preg("mtime lo", 'w', CLINT_MTIME);
    preg("mtime hi", 'w', CLINT_MTIME + 4);
    puts("UART (RBR not read: it pops the byte; LSR read clears OE/BI)");
    /* DLL and DLM sit behind DLAB, where a THR write would land in the divisor:
     * read them first, clear DLAB, then print. */
    uart_flush();
    *reg8(UART_BASE + UART_LCR) |= UART_LCR_DLAB;
    uint32_t dll = *reg8(UART_BASE + 0), dlm = *reg8(UART_BASE + 1);
    *reg8(UART_BASE + UART_LCR) &= ~UART_LCR_DLAB;
    printf("  10000000 DLL              %02x\n  10000001 DLM              %02x\n", dll, dlm);
    static const char *const un[] = {0, "IER", "IIR", "LCR", "MCR", "LSR", "MSR", "SCR"};
    for (int i = 1; i < 8; i++)
        preg(un[i], 'b', UART_BASE + i);
    puts("GPIO and SPI");
    static const struct { const char *n; uint8_t o; } gn[] = {
        {"OUT", 0x00}, {"IN", 0x04}, {"SPICTL", 0x0C}, {"RXDATA", 0x20}, {"TXDATA", 0x24},
        {"STATUS", 0x28}, {"CONTROL", 0x2C}, {"BAUD", 0x30}};
    for (unsigned i = 0; i < sizeof gn / sizeof gn[0]; i++)
        preg(gn[i].n, 'w', 0x10010000 + gn[i].o);
    puts("syscon");
    static const struct { const char *n; uint16_t o; } sn[] = {
        {"RESET_CAUSE", 0x04}, {"BOOT_MODE", 0x08}, {"CHIP_ID", 0x0C}, {"STRAPS", 0x10},
        {"WDT_CR", 0x100}, {"WDT_TORR", 0x104}, {"WDT_COMP_PARAMS", 0x1F4}};
    for (unsigned i = 0; i < sizeof sn / sizeof sn[0]; i++)
        preg(sn[i].n, 'w', SYSCON_BASE + sn[i].o);
}

static void cmd_i(void)
{
    uint32_t v, v2;
    if (!csr_read(0x301, &v)) {
        printf("misa      %08x  ", v);
        for (int i = 0; i < 26; i++)
            if (v & (1u << i))
                uart_putc('A' + i);
        uart_puts("\n");
    }
    static const struct { const char *n; uint16_t c; } ids[] = {
        {"mvendorid", 0xF11}, {"marchid", 0xF12}, {"mimpid", 0xF13}, {"mhartid", 0xF14}};
    for (unsigned i = 0; i < 4; i++)
        if (!csr_read(ids[i].c, &v))
            printf("%-9s %08x\n", ids[i].n, v);
    if (!csr_read(0xB00, &v) && !csr_read(0xB80, &v2))
        printf("mcycle    %08x%08x\n", v2, v);
    if (!csr_read(0xB02, &v) && !csr_read(0xB82, &v2))
        printf("minstret  %08x%08x\n", v2, v);
    uint64_t t = mtime_read();
    printf("mtime     %08x%08x\n", (uint32_t)(t >> 32), (uint32_t)t);
    if (!rd('w', SYSCON_BASE + SYSCON_CHIP_ID, &v))
        printf("CHIP_ID   %08x\n", v);
    if (!rd('w', SYSCON_BASE + SYSCON_RESET_CAUSE, &v))
        printf("RESET_CAUSE %02x (now cleared by the boot)\n", v);
    if (!rd('w', SYSCON_BASE + SYSCON_BOOT_MODE, &v))
        printf("BOOT_MODE %02x\n", v);
    puts("map: flash 20000000-20ffffff, PSRAM 80000000-80ffffff, CLINT 02000000, UART 10000000,");
    puts("     GPIO/SPI 10010000, syscon 10020000");
}

static void help(void)
{
    puts("r [reg [val]]        registers of the stopped program; one; set one (x0-x31, abi names, pc)");
    puts("csr [num|name [val]] CSRs (hex number or name); csr scan [lo hi] tries every number");
    puts("m[b|h|w] addr [n]    dump n units (default 16 words);  w[b|h|w] addr val  write one");
    puts("p                    peripheral registers;  i  ids, counters, reset cause");
    puts("g addr | gb addr     run a program (gb: Ctrl-C stops it);  x  carry on after a stop;  q  power off");
    printf("demos: demo_regs %08x (sets every register, stops)  demo_spin %08x (counts in a0)\n",
           (uint32_t)demo_regs, (uint32_t)demo_spin);
    printf("free RAM from 80100000; a program's stack top is %08x\n", (uint32_t)&_stack_top);
}

static void resume(struct frame *f)
{
    if (break_in)
        tick_on();
    mon_resume(f);
}

static void run(struct frame *f, uint32_t entry, int brk)
{
    memset(f, 0, sizeof *f);
    f->x[1] = (uint32_t)mon_return;
    f->x[2] = (uint32_t)&_stack_top;
    f->mepc = entry & ~1u;
    ctx_valid = 1;
    break_in = brk;
    __asm__ volatile("csrs mstatus, %0" :: "r"(ST_MPP_M));
    if (brk)
        __asm__ volatile("csrs mstatus, %0" :: "r"(ST_MPIE));
    else
        __asm__ volatile("csrc mstatus, %0" :: "r"(ST_MPIE));
    resume(f);
}

static void loop(struct frame *f)
{
    char line[96], *av[4];
    for (;;) {
        uart_puts("> ");
        int n = getline(line, sizeof line), ac = 0;
        char *p = line;
        (void)n;
        while (*p && ac < 4) {
            while (*p == ' ')
                p++;
            if (!*p)
                break;
            av[ac++] = p;
            while (*p && *p != ' ')
                p++;
            if (*p)
                *p++ = 0;
        }
        if (!ac)
            continue;
        const char *c = av[0];
        if (!strcmp(c, "r"))
            cmd_r(f, ac, av);
        else if (!strcmp(c, "csr"))
            cmd_csr(ac, av);
        else if (c[0] == 'm' && (!c[1] || (!c[2] && strchr("bhw", c[1]))))
            cmd_m(c[1] ? c[1] : 'w', ac, av);
        else if (c[0] == 'w' && (!c[1] || (!c[2] && strchr("bhw", c[1]))))
            cmd_w(c[1] ? c[1] : 'w', ac, av);
        else if (!strcmp(c, "p"))
            cmd_p();
        else if (!strcmp(c, "i"))
            cmd_i();
        else if (!strcmp(c, "g") || !strcmp(c, "gb")) {
            uint32_t a;
            if (ac < 2 || !parse_hex(av[1], &a))
                puts("g addr");
            else
                run(f, a, c[1] == 'b');
        } else if (!strcmp(c, "q")) {
            soc_pass();
        } else if (!strcmp(c, "x")) {
            if (!ctx_valid || f->mepc == (uint32_t)mon_return)
                puts("nothing to carry on with");
            else
                resume(f);
        } else if (!strcmp(c, "?") || !strcmp(c, "h"))
            help();
        else
            puts("? (h for help)");
    }
}

/* Every trap from a program arrives here with the registers in *f. */
void mon_trap(struct frame *f)
{
    uint32_t c = f->mcause;
    if (c == 0x80000007u && break_in) {
        int stop = 0;
        if (uart_rx_ready())
            stop = uart_getc() == 3;
        if (!stop) {
            set_mtimecmp(mtime_read() + TICK);
            mon_resume(f);
        }
        puts("^C");
    }
    tick_off();
    ctx_valid = 1;
    uart_puts("\nstopped: ");
    if (c == 3) {
        uint16_t h = *(volatile uint16_t *)f->mepc;
        if (f->mepc == (uint32_t)mon_return) {
            printf("program returned, a0=%08x\n", f->x[10]);
        } else {
            show_stop(f);
            f->mepc += (h & 3) == 3 ? 4 : 2;       /* x carries on after the ebreak */
        }
    } else {
        show_stop(f);
    }
    loop(f);
}

void mon_fatal(void)
{
    uint32_t c, e, t;
    __asm__ volatile("csrr %0, mcause" : "=r"(c));
    __asm__ volatile("csrr %0, mepc" : "=r"(e));
    __asm__ volatile("csrr %0, mtval" : "=r"(t));
    printf("\nMONITOR TRAP mcause=%08x mepc=%08x mtval=%08x\n", c, e, t);
    soc_fail(0xFE);
}

static void start(void)
{
    puts("AlphaOne monitor");
    loop(FRAME);
}

int main(void)
{
    uart_init(UART_DIVISOR);
    uint32_t cause = *reg32(SYSCON_BASE + SYSCON_RESET_CAUSE);
    uint32_t mode = *reg32(SYSCON_BASE + SYSCON_BOOT_MODE);
    *reg32(SYSCON_BASE + SYSCON_RESET_CAUSE) = 0x7;
    __asm__ volatile("csrw mtvec, %0" :: "r"(mon_trap_entry));
    __asm__ volatile("csrw mscratch, zero");
    printf("reset cause %x, boot mode %x\n", cause & 0xFF, mode & 0xFF);
    mon_switch_stack(FRAME, start);
}
