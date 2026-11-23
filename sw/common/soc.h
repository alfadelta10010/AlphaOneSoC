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
#define GPIO_BASE       0x10010000u
#define SYSCON_BASE     0x10020000u

/* The loader's flash layout: the loader runs in place from the first bytes
 * of flash, the image it boots sits at IMAGE_FLASH_OFF behind a header. */
#define IMAGE_FLASH_OFF 0x00010000u
#define IMAGE_MAGIC     0x4D493141u /* "A1IM", little-endian */

/* Image header, 24 bytes, then the payload at IMAGE_FLASH_OFF + 24. */
struct image_hdr {
    uint32_t magic;
    uint32_t load_addr;   /* where the payload goes in PSRAM */
    uint32_t size;        /* payload bytes, a multiple of 4 */
    uint32_t entry;       /* where to jump */
    uint32_t sum;         /* 32-bit sum of the payload words */
    uint32_t flags;       /* IMAGE_F_* */
};
/* The payload services the watchdog (wdt_kick at least every 30 s), so the loader may run the
 * boot-time DDR sweep (ROADMAP 9.1 item 8, docs/qspi-ddr.md section 6): arming the watchdog is
 * how a crash in DDR falls back to SDR, and once armed only a reset turns it off. */
#define IMAGE_F_DDR     0x1u

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

/* GPIO and the SPI controller behind it (src/gpio.v) */
#define GPIO_OUT        0x00          /* bit 0 OLED CS#, 1 MOSI, 3 SCK, 5 SD CS# (4x4); resets to 0xB9 */
#define GPIO_SPICTL     0x0C          /* bit 0 EN: the SPI engine owns MOSI and SCK */
#define GPIO_RXDATA     0x20
#define GPIO_TXDATA     0x24
#define GPIO_STATUS     0x28          /* bit 0 TXE: idle and nothing held */
#define GPIO_CONTROL    0x2C          /* resets to 3: mode 3, as an SD card wants */
#define GPIO_BAUD       0x30          /* SCK = clk / (2 x (BAUD + 1)) */
#define GPIO_SD_CS      0x20     /* 4x4 RTL: OUT bit 5 (bit 7 on main) */
#define GPIO_OLED_CS    0x01

/* syscon */
#define SYSCON_FINISH       0x00
#define SYSCON_RESET_CAUSE  0x04
#define SYSCON_BOOT_MODE    0x08
#define SYSCON_CHIP_ID      0x0C
#define FINISH_PASS         0x5555u
#define FINISH_FAIL         0x3333u   /* (code << 16) | FINISH_FAIL */
#define FINISH_REBOOT       0x7777u
#define SYSCON_STRAPS       0x10
#define SYSCON_QSPI_CFG     0x1C           /* bit 0 STREAM, bit 1 DDR, bits 4:2 DDR_CAP */
#define SYSCON_WDT_CR       0x100          /* DesignWare watchdog: bit 0 EN, once set only a reset clears it */
#define SYSCON_WDT_TORR     0x104          /* TOP in [3:0]: timeout 2^(16+TOP) clocks; a write also kicks */
#define SYSCON_WDT_CRR      0x10C          /* 0x76 kicks */
#define RESET_CAUSE_WDT     0x4
/* BOOT_MODE 0xD8 + k: DDR tried at capture point k; 0xDF: DDR failed (docs/qspi-ddr.md section 6) */
#define BOOT_DDR_TRIED      0xD8
#define BOOT_DDR_FAILED     0xDF

static inline volatile uint8_t  *reg8(uint32_t a)  { return (volatile uint8_t *)a; }
static inline volatile uint32_t *reg32(uint32_t a) { return (volatile uint32_t *)a; }

/* Service the watchdog the loader armed for the DDR attempt. */
static inline void wdt_kick(void) { *reg32(SYSCON_BASE + SYSCON_WDT_CRR) = 0x76; }

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

/* sd.c: an SD card on the SPI controller, in SPI mode (polled) */
int  sd_init(void);                                   /* 0 = ready; sets sd_sdhc */
int  sd_read(uint32_t lba, void *buf);                /* one 512-byte block, 0 = ok */
int  sd_write(uint32_t lba, const void *buf);
int  sd_read_blocks(uint32_t lba, void *buf, uint32_t n);        /* CMD18 + CMD12, n 512-byte blocks, 0 = ok */
int  sd_write_blocks(uint32_t lba, const void *buf, uint32_t n); /* CMD25 + stop token */
extern int sd_sdhc;
extern uint32_t sd_blocks;                             /* size in blocks from the CSD (SDHC/SDXC), 0 = unknown */

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
static inline void soc_pass(void) __attribute__((noreturn));
static inline void soc_pass(void) { soc_finish(FINISH_PASS); }
static inline void soc_fail(unsigned n) __attribute__((noreturn));
static inline void soc_fail(unsigned n) { soc_finish(((uint32_t)n << 16) | FINISH_FAIL); }
/* A payload's crash exit. With DDR on a crash may be the flash failing, and FINISH 0x3333 is a power-off that
 * holds the watchdog in reset: the board would halt until a pin reset and never fall back to SDR. Spin
 * instead, so the watchdog the loader armed resets the SoC and the next boot stays in SDR. */
static inline void soc_crash(unsigned n) __attribute__((noreturn));
static inline void soc_crash(unsigned n)
{
    if (*reg32(SYSCON_BASE + SYSCON_QSPI_CFG) & 2)
    {
        /* Interrupts off first: a crash from task context (configASSERT, the malloc hook) would otherwise keep
         * taking the tick, and a tick hook that kicks the watchdog would keep the board alive forever. */
        __asm__ volatile("csrc mstatus, %0" :: "r"(8u));
        for (;;)
            ;
    }
    soc_fail(n);
}

#endif
