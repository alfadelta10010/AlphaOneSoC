#include "hw.h"

u32 n_chk, n_bad, n_fail_tests, g_mcr0;
const char *t_name;

u32 mtime(void) { return R32(CLINT_MTIME); }

static void putc_(char c) {
    while (!(R8(U_LSR) & 0x20)) ;
    R8(U_THR) = (u8)c;
}
void puts_(const char *s) { while (*s) putc_(*s++); }
void putx(u32 v) {
    int i;
    for (i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}
void putd(u32 v) {
    static const u32 p10[9] = {100000000u, 10000000u, 1000000u, 100000u, 10000u, 1000u, 100u, 10u, 1u};
    int i, started = 0;
    if (v >= 1000000000u) { /* up to 4294967295 */
        u32 d = 0;
        while (v >= 1000000000u) { v -= 1000000000u; d++; }
        putc_('0' + d); started = 1;
    }
    for (i = 0; i < 9; i++) {
        u32 d = 0;
        while (v >= p10[i]) { v -= p10[i]; d++; }
        if (d || started || i == 8) { putc_('0' + d); started = 1; }
    }
}
void uart_drain(void) { while (!(R8(U_LSR) & 0x40)) ; }

void t_begin(const char *name) { t_name = name; n_chk = 0; n_bad = 0; }
void chk(u32 got, u32 exp, const char *what) {
    n_chk++;
    if (got != exp) {
        n_bad++;
        if (n_bad <= 4) {
            puts_("FAIL "); puts_(t_name); putc_(' '); puts_(what);
            puts_(" got="); putx(got); puts_(" exp="); putx(exp); puts_("\n");
        }
    }
}
void t_end(void) {
    if (n_bad) { n_fail_tests++; puts_("FAIL "); puts_(t_name); putc_(' '); putd(n_bad); puts_(" of "); putd(n_chk); puts_(" checks\n"); }
    else { puts_("PASS "); puts_(t_name); putc_(' '); putd(n_chk); puts_(" checks\n"); }
}

int main(void) {
    u32 straps;
    /* The state the program starts in, read before anything is changed. */
    g_mcr0 = R8(U_MCR);
    R8(U_LCR) = 0x80; R8(U_DLL) = DIVISOR & 0xFF; R8(U_DLM) = DIVISOR >> 8; R8(U_LCR) = 0x03;
    R8(U_FCR) = 0x07;                       /* FIFOs on, clear both */
    straps = R32(SC_STRAPS);
    {   /* QSPI_CFG as the image wants it; a DDR image first finds a capture point (from PSRAM code, flash is not read in DDR before) */
        u32 q0 = R32(SC_QCFG), qc = (q0 & ~3u) | (CFG & 3), mask = 0, cap = (q0 >> 2) & 7;
        if (CFG & 2) {
            cap = ddr_pick_cap(qc, q0, &mask);
            if (cap == 8) { qc &= ~2u; cap = (q0 >> 2) & 7; }
            else qc = (qc & ~0x1Cu) | (cap << 2);
        }
        R32(SC_QCFG) = qc;
        puts_("INFO banner ddr_cap="); putd(cap); puts_(" pass_mask="); putx(mask); puts_("\n");
        if ((CFG & 2) && mask == 0) { n_fail_tests++; puts_("FAIL boot no DDR_CAP passes, running SDR\n"); }
    }

    puts_("INFO banner pin="); puts_(PIN_SHA);
    puts_(" F_CLK="); putd(F_CLK); puts_(" div="); putd(DIVISOR);
    puts_(" cfg="); putd(CFG & 3); puts_(" straps="); putx(straps);
    puts_(" qcfg="); putx(R32(SC_QCFG)); puts_("\n");

    t_uart();
    t_flash();
    t_psram();
    t_cache();

    if (n_fail_tests) { puts_("FAILED "); putd(n_fail_tests); puts_("\n"); }
    else puts_("ALL PASS\n");
    uart_drain();
    for (;;) ;
}
