/* Rung 1's payload: runs from PSRAM after the loader has copied it there.
 * Prints a line, shows the ISA string the core reports, and checks that
 * mtime counts the core clock (a known loop is timed with mtime and with mcycle). Stops with PASS through syscon. */
#include "soc.h"

static inline uint32_t csr_misa(void) { uint32_t v; __asm__ volatile("csrr %0, misa" : "=r"(v)); return v; }

int main(void)
{
    uart_puts("Hello, world, from PSRAM!\n");

    uint32_t misa = csr_misa();
    uart_puts("misa=0x");
    uart_puthex(misa, 8);
    uart_puts(" ext:");
    for (int i = 0; i < 26; i++)
        if (misa & (1u << i))
            uart_putc('A' + i);
    uart_puts("\n");

    /* 1000 iterations of a 3-instruction loop, timed twice at once: with mcycle, which counts
     * core clocks, and with mtime. Boot contract rule 7 says they are the same clock, so the
     * two deltas must agree (to 1%: the loads that sample them are a few instructions
     * apart, a few hundred clocks from PSRAM, against a loop of several hundred thousand). */
    uint32_t m0, m1, c0, c1;
    __asm__ volatile("" ::: "memory");
    m0 = *reg32(CLINT_MTIME);
    __asm__ volatile("csrr %0, mcycle" : "=r"(c0));
    for (volatile int i = 0; i < 1000; i++)
        ;
    m1 = *reg32(CLINT_MTIME);
    __asm__ volatile("csrr %0, mcycle" : "=r"(c1));
    uint32_t dt = m1 - m0, dc = c1 - c0;
    uart_puts("1000 loops took ");
    uart_putdec(dt);
    uart_puts(" mtime ticks, ");
    uart_putdec(dc);
    uart_puts(" mcycle clocks\n");

    uint32_t diff = dt > dc ? dt - dc : dc - dt;
    if (dt < 1000 || diff * 100 > dt) {
        uart_puts("FAIL: mtime does not count the core clock\n");
        return 1;
    }
    uart_puts("PASS\n");
    return 0;
}
