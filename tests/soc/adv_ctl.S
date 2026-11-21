/* WO-70 adv_ctl: CACHE_CTL and QSPI_CFG written by code that runs from
 * PSRAM in the middle of line fills, and the "no burst" rules at the pins.
 * tb/tb_adv.v, -DCMODE=0/1/2 (the start mode of phase 1).
 *
 * Spec basis: docs/boot-contract-4x4.md 1.7 (EN may be written at any time,
 * from flash or PSRAM; enabling starts cold; clearing returns to the
 * pass-through; PBURST does nothing without QSPI_CFG.STREAM = 1);
 * docs/pins-and-peripherals.md 12 (CACHE_CTL reads {29'b0, PBURST, 1, EN});
 * WO-68 "Rules the engine enforces" (a PSRAM stream opens only with burst &&
 * stream_en). EXPECTED:
 *   1 200 passes of a PSRAM routine whose 16 blocks each write CACHE_CTL (the
 *     store at line offsets 0x0..0xC, EN and PBURST toggled), half of them
 *     after FENCE.I: the routine's sum is fixed (0x81) and CACHE_CTL reads
 *     back (a3 & 5) | 2 (0x82).
 *   2 EN + PBURST with QSPI_CFG.STREAM = 0: no PSRAM read longer than one
 *     word at the pins (bench, cue 0xB0); STREAM = 1 again: bursts (0xB2).
 *   3 PBURST without EN, 4 EN without PBURST: no bursts.
 *   5 STREAM 1 -> 0 written from word 0 of a cold PSRAM line while its burst
 *     fill runs: correct sum (0x85); afterwards no bursts.
 *   6 STREAM 0 -> 1 the same way: correct sum (0x86).
 * Every routine call checks its sum (0x83 for the 1 KB routine).
 */
#include "adv.h"

#define PCODE  0x80060000
#define WCODE  0x80040000
#define WSUM   32896
#define XCODE  0x80070000
#ifdef DDR_PT
#define QCFG_ON  (1 | 2 | ((DDR_PT) << 2))
#else
#define QCFG_ON  1
#endif

.macro RUNW
    fence.i
    li   a0, 0
    li   t0, WCODE
    jalr ra, 0(t0)
    li   t0, WSUM
    mv   a7, a0
    li   a6, 0x83
    bne  a0, t0, test_fail
.endm
.macro CCTL v
    li   t0, CACHE_CTL
    li   t1, \v
    sw   t1, 0(t0)
.endm

    .section .text.init
    .globl _start
_start:
    ADV_ENTRY trap
    /* the 1 KB routine */
    li   a0, WCODE
    li   t1, 1
1:  slli t2, t1, 20
    li   t3, 0x00050513
    or   t2, t2, t3
    sw   t2, 0(a0)
    addi a0, a0, 4
    addi t1, t1, 1
    li   t3, 257
    blt  t1, t3, 1b
    li   t2, INSN_JR_RA
    sw   t2, 0(a0)
    /* PCODE: 16 blocks of {j%4 x ADDI(j+1), sw a3,0(a1), xori a3,a3,K, 3 x ADDI(j+1)}; s9 = sum */
    li   a0, PCODE
    li   s9, 0
    li   t1, 0                    /* j */
2:  addi t6, t1, 1
    slli t2, t6, 20
    li   t3, 0x00050513
    or   t2, t2, t3               /* ADDI(j+1) */
    andi t4, t1, 3
    addi t4, t4, 3                /* addis in the block */
    andi t5, t1, 3
3:  beqz t5, 4f
    sw   t2, 0(a0)
    addi a0, a0, 4
    addi t5, t5, -1
    j    3b
4:  li   t3, 0x00D5A023           /* sw a3, 0(a1) */
    sw   t3, 0(a0)
    li   t3, 3
    remu t5, t1, t3
    li   t3, 0x0016C693           /* xori a3, a3, 1 */
    beqz t5, 5f
    li   t3, 0x0046C693           /* xori a3, a3, 4 */
    li   a5, 1
    beq  t5, a5, 5f
    li   t3, 0x0056C693           /* xori a3, a3, 5 */
5:  sw   t3, 4(a0)
    sw   t2, 8(a0)
    sw   t2, 12(a0)
    sw   t2, 16(a0)
    addi a0, a0, 20
    mul  t5, t4, t6
    add  s9, s9, t5
    addi t1, t1, 1
    li   t3, 16
    blt  t1, t3, 2b
    li   t2, INSN_JR_RA
    sw   t2, 0(a0)

/* ── Phase 1 ── */
    li   s4, 0x5A5A1234
    li   s3, 0
6:  LFSR
    andi a3, s4, 5
    li   a1, CACHE_CTL
    andi t0, s4, 0x100
    beqz t0, 7f
    fence.i
7:  li   a0, 0
    li   t0, PCODE
    jalr ra, 0(t0)
    mv   a7, a0
    li   a6, 0x81
    bne  a0, s9, test_fail
    li   t0, CACHE_CTL
    lw   t1, 0(t0)
    andi t2, a3, 5
    ori  t2, t2, 2
    mv   a7, t1
    li   a6, 0x82
    bne  t1, t2, test_fail
    SIGF a0
    addi s3, s3, 1
    li   t0, 200
    blt  s3, t0, 6b

/* ── Phase 2: EN + PBURST, STREAM = 0 ── */
    CCTL 5
    sw   zero, QSPI_CFG(s11)
    EVENT 0xB0
    RUNW
    RUNW
    EVENT 0xB1
    li   t1, QCFG_ON
    sw   t1, QSPI_CFG(s11)
    RUNW
    EVENT 0xB2
/* ── Phase 3: PBURST without EN ── */
    CCTL 4
    EVENT 0xB0
    RUNW
    EVENT 0xB1
/* ── Phase 4: EN without PBURST ── */
    CCTL 1
    EVENT 0xB0
    RUNW
    RUNW
    EVENT 0xB1
/* ── Phase 5: STREAM 1 -> 0 from word 0 of a cold line ── */
    /* XCODE: sw zero, 0x1C(s11); 11 x ADDI(1); jr ra */
    li   a0, XCODE
    li   t1, 0x000DAE23           /* sw zero, 0x1C(s11) */
    sw   t1, 0(a0)
    li   t1, ADDI_A0(1)
    li   t2, 11
8:  sw   t1, 4(a0)
    addi a0, a0, 4
    addi t2, t2, -1
    bnez t2, 8b
    li   t1, INSN_JR_RA
    sw   t1, 4(a0)
    CCTL 5
    RUNW
    EVENT 0xB2                    /* the setup really bursts */
    fence.i
    li   a0, 0
    li   t0, XCODE
    jalr ra, 0(t0)
    mv   a7, a0
    li   a6, 0x85
    li   t1, 11
    bne  a0, t1, test_fail
    DELAY 400
    EVENT 0xB0
    RUNW
    EVENT 0xB1
/* ── Phase 6: STREAM 0 -> 1 the same way ── */
    li   a0, XCODE
    li   t1, 0x01ADAE23           /* sw s10, 0x1C(s11) */
    sw   t1, 0(a0)
    fence.i
    mv   t6, s10
    li   s10, QCFG_ON
    li   a0, 0
    li   t0, XCODE
    jalr ra, 0(t0)
    mv   s10, t6
    mv   a7, a0
    li   a6, 0x86
    li   t1, 11
    bne  a0, t1, test_fail
    lw   t1, QSPI_CFG(s11)
    mv   a7, t1
    li   a6, 0x87
    li   t2, QCFG_ON
    bne  t1, t2, test_fail
    RUNW
    SIGF a0
    ADV_PASS

    .balign 4                    /* mtvec BASE is 4-byte aligned: the low bits are its MODE field (WARL) */
trap:
    csrr a7, mcause
    csrr t0, mepc
    sw   t0, MB_VALUE(s11)
    li   a6, 0x7E
    j    test_fail

    ADV_FAIL_BODY
