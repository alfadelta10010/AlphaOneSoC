/* Stand-in for riscv-tests' benchmarks/common/util.h, which the Dhrystone
 * sources include: the pieces they use, on this SoC. */
#ifndef UTIL_H
#define UTIL_H

#include <stdint.h>
#include "soc.h"

/* dhrystone.h times a run with read_csr(mcycle) at HZ = 10^6, so the
 * "Dhrystones per Second" it prints is Dhrystones per second at 1 MHz, i.e.
 * Dhrystones per MHz. DMIPS/MHz = that / 1757. */
#define read_csr(reg) ({ unsigned long __v; __asm__ volatile ("csrr %0, " #reg : "=r"(__v)); __v; })

static inline void setStats(int enable) { (void)enable; }

void debug_printf(const char *fmt, ...);

#endif
