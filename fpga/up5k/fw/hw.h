#ifndef HW_H
#define HW_H
typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;
typedef signed char    s8;
typedef short          s16;

#ifndef F_CLK
#define F_CLK 20000000
#endif
#ifndef CFG
#define CFG 1                 /* boot QSPI_CFG bits [1:0]: bit0 STREAM, bit1 DDR */
#endif
#ifndef PIN_SHA
#define PIN_SHA "unknown"
#endif
#define BAUD 115200
#define DIVISOR ((F_CLK + 8 * BAUD) / (16 * BAUD))     /* constant-folded, no runtime divide */

#define R8(a)  (*(volatile u8  *)(a))
#define R32(a) (*(volatile u32 *)(a))

#define UART     0x10000000u
#define U_RBR    (UART + 0)   /* DLAB=0 read; THR write; DLL with DLAB */
#define U_THR    (UART + 0)
#define U_DLL    (UART + 0)
#define U_IER    (UART + 1)
#define U_DLM    (UART + 1)
#define U_IIR    (UART + 2)
#define U_FCR    (UART + 2)
#define U_LCR    (UART + 3)
#define U_MCR    (UART + 4)
#define U_LSR    (UART + 5)
#define U_MSR    (UART + 6)
#define U_SCR    (UART + 7)

#define SYSCON    0x10020000u
#define SC_STRAPS (SYSCON + 0x10)
#define SC_QCFG   (SYSCON + 0x1C)
#define CACHE_CTL (SYSCON + 0x24)
#define CLINT_MTIME 0x0200BFF8u
#define PLIC_PEND   0x0C001000u

/* flash window, PSRAM windows */
#define PSRAM_A  0x80000000u
#define PSRAM_B  0x80800000u
#define TW_BASE  0x80010000u   /* 64 KB test window, PSRAM A; the stack lives just below it */

extern const u32 pattern[];   /* flash, 1 KB aligned */
#define PAT_WORDS 512         /* checked region; 4 more words follow it (gen_pattern.py) */

/* uart + test framework */
void puts_(const char *s);
void putx(u32 v);
void putd(u32 v);
void uart_drain(void);
u32  mtime(void);

extern const char *t_name;
extern u32 g_mcr0;
void t_begin(const char *name);
void chk(u32 got, u32 exp, const char *what);
void t_end(void);

void t_uart(void);
void t_flash(void);
void t_psram(void);
void t_cache(void);
extern u32 n_fail_tests;
#endif
