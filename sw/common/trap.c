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
    soc_fail(0xFF);
}
