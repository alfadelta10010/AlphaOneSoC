/* Default trap handler: say what happened, then stop with a failure. The
 * stack is reset by the entry stub, so this works after any trap. */
#include "soc.h"

static inline uint32_t csr_mcause(void) { uint32_t v; __asm__ volatile("csrr %0, mcause" : "=r"(v)); return v; }
static inline uint32_t csr_mepc(void)   { uint32_t v; __asm__ volatile("csrr %0, mepc"   : "=r"(v)); return v; }
static inline uint32_t csr_mtval(void)  { uint32_t v; __asm__ volatile("csrr %0, mtval"  : "=r"(v)); return v; }

void trap_report(void)
{
    uart_puts("\nTRAP mcause=0x");
    uart_puthex(csr_mcause(), 8);
    uart_puts(" mepc=0x");
    uart_puthex(csr_mepc(), 8);
    uart_puts(" mtval=0x");
    uart_puthex(csr_mtval(), 8);
    uart_puts("\n");
    /* With DDR on, a trap may be the flash failing. FINISH 0x3333 is a power-off, which holds the watchdog
     * in reset: the board would halt until a pin reset and never fall back to SDR. Spin instead, so the
     * watchdog the loader armed (BOOT_MODE 0xD8 + k) resets the SoC and the next boot stays in SDR. */
    if (*reg32(SYSCON_BASE + SYSCON_QSPI_CFG) & 2)
        for (;;)
            ;
    soc_fail(0xFF);
}
