/* Addresses and helpers for the 4x4 SoC programs (PLIC, gamepad, PWM, audio, pinmux, SD CS# on OUT 5).
 * Included after periph.h. Addresses: localFiles/wo-4x4/INDEX-4x4.md decisions D1-D5, D8, D9.
 * Conventions in these programs: s11 = SYSCON, s2 = PLIC base, a4 = PLIC context 0 base. The programs
 * poll mip.MEIP with mstatus.MIE off (no trap handler), so the PLIC's claim / complete sequence is the
 * only interrupt plumbing under test. */
#include "periph.h"
#define PLIC      0x0C000000
#define PL_PRIO   0x04            /* source n at PL_PRIO * n */
#define PL_PEND   0x1000
#define PL_EN     0x2000
#define PL_CTX    0x200000        /* threshold +0, claim / complete +4 */
#define PWM       0x10030000
#define AUDIO     0x10030100
#define PINMUX    0x10020020      /* pin i's code in bits [4i+2:4i] */
#define G_PAD     0x10            /* GPIO window: GAMEPAD, read only */
#define G_PADSTAT 0x14            /* GPSTAT: bit 0 chg (W1C), bit 1 ie */
/* PLIC sources */
#define SRC_UART  1
#define SRC_SPI   2
#define SRC_PAD   3
#define SRC_GPIO  4
#define SRC_PWM0  5
/* pwm (sifive pwm0) */
#define PWM_CFG   0x00
#define PWM_COUNT 0x08
#define PWM_S     0x10
#define PWM_CMP0  0x20
/* audio */
#define AU_TONE0  0x00
#define AU_TONE1  0x04   /* offsets 0x04..0x0C and 0x14 are not built (read 0) */
#define AU_TONE2  0x08
#define AU_NOISE  0x0C
#define AU_CTRL   0x10
#define AU_PCM    0x14
/* one UART character in clocks (8N1, 16 x divisor) */
#define CHAR_CLKS (160 * UART_DIV_RESET)

/* PLIC probe + setup: priorities 1 for sources 1..9, enable word = mask, threshold 0.
 * Sets s2 = PLIC, a4 = context base. Clobbers t0-t2. */
.macro PLIC_SETUP mask
    li   s2, PLIC
    li   a4, PLIC + PL_CTX
    li   t0, 1
    li   t1, 9
    addi t2, s2, PL_PRIO
87: sw   t0, 0(t2)
    addi t2, t2, 4
    addi t1, t1, -1
    bnez t1, 87b
    li   t2, PLIC + PL_EN
    li   t0, \mask
    sw   t0, 0(t2)
    sw   zero, 0(a4)
    li   t0, 0x800
    csrw mie, t0                  /* MEIE; mstatus.MIE stays 0: mip is polled */
.endm
/* Wait (bounded) for mip.MEIP, else fail `code` with a7 = 0 (clobbers t4, t5, a6, a7). */
.macro WAIT_MEIP code
    li   t4, 400000
89: csrr t5, mip
    srli t5, t5, 11
    andi t5, t5, 1
    bnez t5, 88f
    addi t4, t4, -1
    bnez t4, 89b
    li   a7, 0
    li   a6, \code
    j    test_fail
88:
.endm
/* MEIP must be clear (clobbers t5, a6, a7) */
.macro NO_MEIP code
    csrr t5, mip
    srli t5, t5, 11
    andi t5, t5, 1
    CHECK t5, 0, \code
.endm
/* claim must return `id` (t0 = claim; clobbers t5, a6, a7) */
.macro CLAIM id, code
    lw   t0, 4(a4)
    CHECK t0, \id, \code
.endm
.macro COMPLETE
    sw   t0, 4(a4)
.endm
/* A cue the bench acts on, then `n` clocks for the action to be done and measured. */
.macro CUE code, n
    EVENT_P \code
    DELAY \n
.endm
