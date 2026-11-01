/* Rung 1's payload: runs from PSRAM after the loader has copied it there.
 * Prints a line, shows the ISA string the core reports, and checks that
 * mtime counts the core clock (a known loop takes a plausible number of
 * clocks). Stops with PASS through syscon. */
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

    /* 1000 iterations of a 3-instruction loop. From PSRAM each fetch costs
     * tens of clocks, so the count is large but bounded; the check is that
     * mtime moved at all and not by an absurd amount. */
    uint64_t t0 = mtime_read();
    for (volatile int i = 0; i < 1000; i++)
        ;
    uint32_t dt = (uint32_t)(mtime_read() - t0);
    uart_puts("1000 loops took ");
    uart_putdec(dt);
    uart_puts(" clocks\n");

    if (dt < 1000 || dt > 2000000) {
        uart_puts("FAIL: mtime not plausible\n");
        return 1;
    }
    uart_puts("PASS\n");
    return 0;
}
