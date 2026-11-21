/* WO-70 adversarial programs (tb/tb_adv.v): shared definitions.
 * Mailbox and FINISH codes as tests/soc/periph.h. s11 = SYSCON, s10 = the
 * signature (folded with SIGF), the rest is each program's.
 *
 * -DCMODE=n picks the instruction-cache mode the program runs in, written to
 * CACHE_CTL (docs/pins-and-peripherals.md 12) right after mtvec:
 *   0 = off, 1 = EN, 2 = EN + PBURST. The same program must give the same
 * signature in all three (the cache is architecturally invisible).
 * -DDDR_PT=n additionally switches QSPI_CFG to DDR with capture point n
 * (docs/boot-contract-4x4.md 3; the bench's delays must match the point).
 */

#include "periph4.h"

#define CACHE_CTL 0x10020024
#define QSPI_CFG  0x1C
#define RST_CAUSE 0x04
#define BOOT_MODE 0x08
#define WDT_CR    0x100
#define WDT_TORR  0x104
#define WDT_CRR   0x10C
#define WDT_STAT  0x110
#define WDT_EOI   0x114
#define SRC_WDT   9

#ifndef CMODE
#define CMODE 0
#endif
#if CMODE == 0
#define CCTL_VAL 0
#elif CMODE == 1
#define CCTL_VAL 1
#else
#define CCTL_VAL 5
#endif

/* ADDI a0, a0, imm */
#define ADDI_A0(imm) ((((imm) & 0xFFF) << 20) | 0x00050513)
#define INSN_JR_RA   0x00008067
#define INSN_NOP     0x00000013

/* s10 = rotl(s10, 5) ^ r  (clobbers t5) */
.macro SIGF r
    slli t5, s10, 5
    srli s10, s10, 27
    or   s10, s10, t5
    xor  s10, s10, \r
.endm

/* Galois LFSR step on s4 (32-bit, taps 0x80200003); clobbers t5 */
.macro LFSR
    srli t5, s4, 1
    andi s4, s4, 1
    neg  s4, s4
    li   a5, 0x80200003
    and  s4, s4, a5
    xor  s4, s4, t5
.endm

/* common entry: mtvec, SYSCON, cache mode, optional DDR */
.macro ADV_ENTRY handler
    la   t0, \handler
    csrw mtvec, t0
    li   s11, SYSCON
    li   s10, 0
    MB_INIT
#ifdef DDR_PT
    li   t0, (1 | 2 | ((DDR_PT) << 2))
    sw   t0, QSPI_CFG(s11)
#endif
    li   t0, CACHE_CTL
    li   t1, CCTL_VAL
    sw   t1, 0(t0)
    lw   t2, 0(t0)
    li   t1, (CCTL_VAL | 2)
    beq  t1, t2, 77f
    mv   a7, t2
    li   a6, 0x7F
    j    test_fail
77:
.endm

/* report the signature, then pass */
.macro ADV_PASS
    EVENT 0x5C
    sw   s10, MB_VALUE(s11)
    li   t6, UART
    WAIT_LSR t6, LSR_TEMT
    li   t0, FINISH_PASS
    sw   t0, MB_FINISH(s11)
1:  j    1b
.endm

/* test_fail: a6 = code, a7 = value seen */
.macro ADV_FAIL_BODY
test_fail:
    li   s11, SYSCON
    sw   a7, MB_VALUE2(s11)
    slli a6, a6, 16
    li   t0, FINISH_FAIL
    or   a6, a6, t0
    sw   a6, MB_FINISH(s11)
1:  j    1b
.endm

/* copy n words from flash symbol src to PSRAM address in a0 (clobbers t0-t3) */
.macro COPYW src, nwords
    la   t0, \src
    li   t1, \nwords
1:  lw   t2, 0(t0)
    sw   t2, 0(a0)
    addi t0, t0, 4
    addi a0, a0, 4
    addi t1, t1, -1
    bnez t1, 1b
.endm
