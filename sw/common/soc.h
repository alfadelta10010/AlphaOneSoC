/* AlphaOneSoC addresses and register access for bare-metal C.
 * Layout: docs/soc-architecture.md. Boot contract: docs/ROADMAP.md 9.1. */
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define CLK_HZ          62500000u   /* the core clock; mtime counts it (ROADMAP 9.1 rule 7) */

#define FLASH_BASE      0x20000000u
#define PSRAM_BASE      0x80000000u
#define PSRAM_SIZE      0x01000000u

#define CLINT_MTIMECMP  0x02004000u
#define CLINT_MTIME     0x0200BFF8u
#define UART_BASE       0x10000000u
#define SYSCON_BASE     0x10020000u

/* The loader's flash layout: the loader runs in place from the first bytes
 * of flash, the image it boots sits at IMAGE_FLASH_OFF behind a header. */
#define IMAGE_FLASH_OFF 0x00010000u
#define IMAGE_MAGIC     0x4D493141u /* "A1IM", little-endian */

/* Image header, 20 bytes, then the payload at IMAGE_FLASH_OFF + 20. */
struct image_hdr {
    uint32_t magic;
    uint32_t load_addr;   /* where the payload goes in PSRAM */
    uint32_t size;        /* payload bytes, a multiple of 4 */
    uint32_t entry;       /* where to jump */
    uint32_t sum;         /* 32-bit sum of the payload words */
};

/* UART (16550 subset, byte registers) */
#define UART_THR        0
#define UART_DLL        0
#define UART_DLM        1
#define UART_LCR        3
#define UART_LSR        5
#define UART_LCR_DLAB   0x80
#define UART_RBR        0
#define UART_LSR_DR     0x01
#define UART_LSR_THRE   0x20
#define UART_LSR_TEMT   0x40
/* Boot contract rule 2: 114,890 baud at 62.5 MHz (115,200 - 0.27%). */
#define UART_DIVISOR    34

/* syscon */
#define SYSCON_FINISH       0x00
#define SYSCON_RESET_CAUSE  0x04
#define SYSCON_BOOT_MODE    0x08
#define SYSCON_CHIP_ID      0x0C
#define FINISH_PASS         0x5555u
#define FINISH_FAIL         0x3333u   /* (code << 16) | FINISH_FAIL */
#define FINISH_REBOOT       0x7777u

static inline volatile uint8_t  *reg8(uint32_t a)  { return (volatile uint8_t *)a; }
static inline volatile uint32_t *reg32(uint32_t a) { return (volatile uint32_t *)a; }

/* mtime, read so that a carry between the halves cannot give a wrong value. */
static inline uint64_t mtime_read(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi  = *reg32(CLINT_MTIME + 4);
        lo  = *reg32(CLINT_MTIME);
        hi2 = *reg32(CLINT_MTIME + 4);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* uart.c */
void uart_init(unsigned divisor);
void uart_putc(int c);
void uart_flush(void);
int  uart_getc(void);          /* blocks */
int  uart_rx_ready(void);
void uart_puts(const char *s);
void uart_puthex(uint32_t v, int digits);
void uart_putdec(uint32_t v);

/* Stop the run through syscon. FINISH needs a halfword or word store. */
void soc_finish(uint32_t code) __attribute__((noreturn));
static inline void soc_pass(void) { soc_finish(FINISH_PASS); }
static inline void soc_fail(unsigned n) { soc_finish(((uint32_t)n << 16) | FINISH_FAIL); }

#endif
