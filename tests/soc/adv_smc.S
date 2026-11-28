/* WO-70 adv_smc: stores into code lines that are being filled, self-modifying
 * code, line-boundary fetches. tb/tb_adv.v; build -DCMODE=0/1/2 (cache off,
 * EN, EN+PBURST): the signature must be the same in all three.
 *
 * Spec basis: docs/pins-and-peripherals.md 12 ("Stores, AMOs and successful
 * SCs that complete on the data port invalidate their line, so no flush is
 * needed for coherence"; FENCE.I flushes); RISC-V Zifencei (after FENCE.I
 * the hart sees its own earlier stores to instruction memory); the address
 * map (PSRAM A/B at addr[23], the PSRAM window ends at 0x80FF_FFFF).
 *
 * Part A, the fill-race matrix. For op x entry word e x target slot s x
 * {no FENCE.I, FENCE.I}: a cold PSRAM line L holds ADDI a0,a0,(1<<k) in
 * words k != e and the store under test in word e, aimed at word s with the
 * new word ADDI a0,a0,(1<<s)+0x100. Pass 1 jumps to word e: the store runs
 * while the line is still being filled (e = 0: three words still to come).
 * Pass 2 runs the whole line from word 0 (the store now aimed at a dummy
 * word) either straight away (no FENCE.I: the doc's snoop promise) or after
 * FENCE.I (Zifencei). EXPECTED: pass 2 = sum over k of {k==s: (1<<k)+0x100,
 * k==e: 0, else 1<<k} for every op that writes, slot s unchanged for the
 * failing SC. Ops: 0 sw, 1 sh (upper half), 2 sb (byte 3), 3 amoswap,
 * 4 amoadd, 5 lr(flash)/sc(line) success, 6 sc after an lr of another
 * address (must fail and write nothing). Pass 1 is recorded in a second
 * signature only (old or new is legal while the store's successor is in
 * flight). Fail codes 0x21 (with FENCE.I), 0x22 (without), 0x25 SC that
 * must succeed failed, 0x26 SC that must fail succeeded.
 *
 * Part B, SMC loop: NITER iterations; a random 32-bit ADDI of two regions
 * (R1: every instruction at offset 2 mod 4, so one in four straddles a line;
 * R2: word aligned) is rewritten (R1 with two sh, R2 with one sw), FENCE.I,
 * then one region runs from its start or from a random instruction (entry
 * offsets 0x0..0xE in steps of 2 over the two regions). EXPECTED: a0 = the
 * sum of the shadow immediates from the entry on. Fail code 0x31.
 *
 * Part C, boundaries: a 32-bit ADDI straddling PSRAM A/B (0x807F_FFFE),
 * entered cold at the line start and at the straddler, then warm; the last
 * PSRAM line (0x80FF_FFF0); a 32-bit instruction straddling the end of the
 * PSRAM window (0x80FF_FFFE): EXPECTED instruction access fault, mcause 1,
 * mepc 0x80FF_FFFE (mtval in the signature only). Fail codes 0x41-0x45.
 */
#include "adv.h"

#ifndef NITER
#define NITER 1000
#endif
#ifndef SEED
#define SEED 0x1234ABCD
#endif
#define MAT   0x80010000          /* part A lines, 32 B per combination */
#define DUMMY 0x8000F000
#define R1    0x80004000
#define R2    0x80005000
#define SHAD  0x80006000
#define NR    32

    .section .text.init
    .globl _start
_start:
    ADV_ENTRY trap
    li   gp, 0                    /* recovery pc for an expected trap; 0 = none */

/* ── Part A ─────────────────────────────────────────────────────────────── */
    li   s9, MAT
    li   s8, 0
    li   s7, 0
    li   s6, 0
    li   a1, 0
    li   s0, 0
op_loop:
    li   s1, 0
e_loop:
    li   s2, 0
s_loop:
    bne  s1, s2, 1f
    li   t0, 1
    beq  s0, t0, next_s
    li   t0, 2
    beq  s0, t0, next_s
    li   t0, 4
    beq  s0, t0, next_s
1:  li   s3, 0
f_loop:
    slli t0, s8, 5
    add  a2, s9, t0               /* a2 = L */
    li   t1, 0
bld:
    li   t2, 1
    sll  t2, t2, t1
    slli t2, t2, 20
    li   t3, 0x00050513
    or   t2, t2, t3
    bne  t1, s1, 2f
    la   t4, st_tab
    slli t5, s0, 2
    add  t4, t4, t5
    lw   t2, 0(t4)
2:  slli t5, t1, 2
    add  t5, a2, t5
    sw   t2, 0(t5)
    addi t1, t1, 1
    li   t5, 4
    blt  t1, t5, bld
    li   t2, INSN_JR_RA
    sw   t2, 16(a2)
    li   t2, INSN_NOP
    sw   t2, 20(a2)
    sw   t2, 24(a2)
    sw   t2, 28(a2)
    fence.i
    /* a3 = the new word, a4 = slot address */
    li   t2, 1
    sll  t2, t2, s2
    addi t2, t2, 0x100
    slli t2, t2, 20
    li   t3, 0x00050513
    or   a3, t2, t3
    slli t0, s2, 2
    add  a4, a2, t0
    mv   t3, a4
    mv   t1, a3
    li   t0, 1
    bne  s0, t0, 3f
    addi t3, a4, 2                /* sh: upper half */
    srli t1, a3, 16
3:  li   t0, 2
    bne  s0, t0, 3f
    addi t3, a4, 3                /* sb: byte 3 */
    srli t1, a3, 24
3:  li   t0, 4
    bne  s0, t0, 3f
    li   t1, 0x10000000           /* amoadd: imm += 0x100 */
3:  slli t5, s1, 2
    add  t5, a2, t5               /* entry = word e */
    li   a0, 0
    li   t4, 0
    li   t0, 5
    bne  s0, t0, 3f
    lr.w t4, (t3)
    jalr ra, 0(t5)
    j    4f
3:  li   t0, 6
    bne  s0, t0, 3f
    li   t0, DUMMY
    lr.w t4, (t0)
    jalr ra, 0(t5)
    j    4f
3:  jalr ra, 0(t5)
4:  /* pass 1 done: a0 = pass-1 sum, t4 = SC result for ops 5/6 */
    slli t5, a1, 5
    srli a1, a1, 27
    or   a1, a1, t5
    xor  a1, a1, a0
    li   t0, 5
    bne  s0, t0, 5f
    mv   a7, t4
    li   a6, 0x25
    bnez t4, test_fail
5:  li   t0, 6
    bne  s0, t0, 5f
    mv   a7, s8
    li   a6, 0x26
    beqz t4, test_fail
5:  beqz s3, 6f
    fence.i
6:  li   t3, DUMMY
    li   t1, 0
    li   a0, 0
    jalr ra, 0(a2)                /* pass 2 */
    /* expected */
    li   a5, 0
    li   t1, 0
7:  li   t2, 1
    sll  t2, t2, t1
    bne  t1, s2, 8f
    li   t0, 6
    beq  s0, t0, 8f
    addi t2, t2, 0x100
    j    9f
8:  bne  t1, s1, 9f
    li   t2, 0
9:  add  a5, a5, t2
    addi t1, t1, 1
    li   t0, 4
    blt  t1, t0, 7b
    SIGF a0
    beq  a0, a5, 10f
    /* mismatch: count it, report {combo, f, got} on the spare word */
    slli t0, s8, 20
    slli t1, s3, 16
    or   t0, t0, t1
    or   t0, t0, a0
    sw   t0, MB_SPARE(s11)
    beqz s3, 11f
    addi s7, s7, 1
    j    10f
11: addi s6, s6, 1
10: addi s8, s8, 1
    addi s3, s3, 1
    li   t0, 2
    blt  s3, t0, f_loop
next_s:
    addi s2, s2, 1
    li   t0, 4
    blt  s2, t0, s_loop
    addi s1, s1, 1
    blt  s1, t0, e_loop
    addi s0, s0, 1
    li   t0, 7
    blt  s0, t0, op_loop
    EVENT 0x5C
    sw   a1, MB_VALUE(s11)        /* the pass-1 signature (reported, not compared) */
    mv   a7, s7
    li   a6, 0x21
    bnez s7, test_fail
    mv   a7, s6
    li   a6, 0x22
    bnez s6, test_fail

/* ── Part B ─────────────────────────────────────────────────────────────── */
    li   s4, SEED
    li   s5, 0
    li   s7, 0
    /* R1: c.nop, NR x ADDI a0,a0,0 at offset 2 + 4i, then jr ra (all by halves) */
    li   a0, R1
    li   t0, 0x0001
    sh   t0, 0(a0)
    li   t1, 0
    li   t2, 0x00050513
    li   a2, R2
    li   a3, SHAD
1:  slli t3, t1, 2
    add  t4, a0, t3
    sh   t2, 2(t4)
    srli t5, t2, 16
    sh   t5, 4(t4)
    add  t4, a2, t3
    sw   t2, 0(t4)
    add  t4, a3, t3
    sw   zero, 0(t4)
    addi t1, t1, 1
    li   t0, NR
    blt  t1, t0, 1b
    li   t2, INSN_JR_RA
    sh   t2, 2 + 4 * NR(a0)
    srli t5, t2, 16
    sh   t5, 4 + 4 * NR(a0)
    sw   t2, 4 * NR(a2)
    li   s3, 0                    /* iteration */
b_loop:
    LFSR
    andi t0, s4, NR - 1           /* idx */
    srli t1, s4, 8
    andi t1, t1, 0x7FF            /* imm */
    slli t2, t1, 20
    li   t3, 0x00050513
    or   t2, t2, t3               /* new word */
    slli t3, t0, 2
    li   t4, R1
    add  t4, t4, t3
    sh   t2, 2(t4)
    srli t5, t2, 16
    sh   t5, 4(t4)
    li   t4, R2
    add  t4, t4, t3
    sw   t2, 0(t4)
    li   t4, SHAD
    add  t4, t4, t3
    lw   t5, 0(t4)
    sw   t1, 0(t4)
    sub  s5, s5, t5
    add  s5, s5, t1
    fence.i
    /* entry: start (expected s5) or a random instruction (suffix sum) */
    srli t0, s4, 20
    andi t0, t0, 3
    li   a5, 0                    /* entry index */
    mv   a4, s5
    bnez t0, 2f
    srli a5, s4, 22
    andi a5, a5, NR - 1
    li   a4, 0
    li   t4, SHAD
    slli t3, a5, 2
    add  t4, t4, t3
    li   t2, SHAD + 4 * NR
3:  lw   t5, 0(t4)
    add  a4, a4, t5
    addi t4, t4, 4
    blt  t4, t2, 3b
2:  srli t0, s4, 24
    andi t0, t0, 1
    slli t3, a5, 2
    li   t4, R2
    bnez t0, 4f
    li   t4, R1 + 2               /* R1's instruction i is at R1 + 2 + 4i */
    bnez a5, 4f
    li   t4, R1                   /* from the start: through the c.nop */
4:  add  t4, t4, t3
    li   a0, 0
    jalr ra, 0(t4)
    SIGF a0
    beq  a0, a4, 5f
    addi s7, s7, 1
    slli t0, s3, 16
    or   t0, t0, a0
    sw   t0, MB_SPARE(s11)
5:  addi s3, s3, 1
    li   t0, NITER
    blt  s3, t0, b_loop
    mv   a7, s7
    li   a6, 0x31
    bnez s7, test_fail

/* ── Part C ─────────────────────────────────────────────────────────────── */
    /* C1: 0x807FFFF0: addi 1, addi 2, addi 4, c.nop, [FE] addi 8 (straddles A/B), [0x80800002] c.jr ra */
    li   a0, 0x807FFFF0
    li   t0, ADDI_A0(1)
    sw   t0, 0(a0)
    li   t0, ADDI_A0(2)
    sw   t0, 4(a0)
    li   t0, ADDI_A0(4)
    sw   t0, 8(a0)
    li   t0, 0x0001
    sh   t0, 12(a0)
    li   t0, ADDI_A0(8)
    sh   t0, 14(a0)
    srli t0, t0, 16
    sh   t0, 16(a0)
    li   t0, 0x8082
    sh   t0, 18(a0)
    li   t0, 0x0001
    sh   t0, 20(a0)
    sh   t0, 22(a0)
    fence.i
    li   a0, 0
    li   t4, 0x807FFFF0
    jalr ra, 0(t4)
    mv   a7, a0
    li   a6, 0x41
    li   t0, 15
    bne  a0, t0, test_fail
    fence.i
    li   a0, 0
    li   t4, 0x807FFFFE
    jalr ra, 0(t4)
    mv   a7, a0
    li   a6, 0x42
    li   t0, 8
    bne  a0, t0, test_fail
    li   a0, 0
    li   t4, 0x807FFFF0
    jalr ra, 0(t4)                /* warm (where cached) */
    mv   a7, a0
    li   a6, 0x43
    li   t0, 15
    bne  a0, t0, test_fail
    /* C2: the last PSRAM line */
    li   a0, 0x80FFFFF0
    li   t0, ADDI_A0(1)
    sw   t0, 0(a0)
    li   t0, ADDI_A0(2)
    sw   t0, 4(a0)
    li   t0, ADDI_A0(4)
    sw   t0, 8(a0)
    li   t0, INSN_JR_RA
    sw   t0, 12(a0)
    fence.i
    li   a0, 0
    li   t4, 0x80FFFFF0
    jalr ra, 0(t4)
    mv   a7, a0
    li   a6, 0x44
    li   t0, 7
    bne  a0, t0, test_fail
    /* C3: a 32-bit instruction straddling the end of the PSRAM window */
    li   a0, 0x80FFFFFC
    li   t0, 0x0001
    sh   t0, 0(a0)
    li   t0, ADDI_A0(16)
    sh   t0, 2(a0)                /* low half at 0x80FFFFFE; the high half would be at 0x8100_0000 */
    fence.i
    la   gp, c3_back
    li   a0, 0
    li   t4, 0x80FFFFFC
    jalr ra, 0(t4)
    li   a6, 0x45                 /* fell through: no fault */
    mv   a7, a0
    j    test_fail
c3_back:
    li   gp, 0
    mv   a7, s1                   /* s1 = mcause, s2 = mepc from the handler */
    li   a6, 0x46
    li   t0, 1
    bne  s1, t0, test_fail
    mv   a7, s2
    li   a6, 0x47
    li   t0, 0x80FFFFFE
    bne  s2, t0, test_fail
    ADV_PASS

    .balign 4                    /* mtvec BASE is 4-byte aligned: the low bits are its MODE field (WARL) */
trap:
    csrr s1, mcause
    csrr s2, mepc
    csrr t0, mtval
    beqz gp, 1f
    SIGF s1
    SIGF s2
    sw   t0, MB_SPARE(s11)        /* mtval: reported, not in the signature (implementation choice) */
    csrw mepc, gp
    mret
1:  mv   a7, s1
    sw   s2, MB_VALUE(s11)
    li   a6, 0x7E
    j    test_fail

    ADV_FAIL_BODY

    .section .rodata
    .balign 4
st_tab:
    .word 0x006E2023              /* 0 sw      t1, 0(t3) */
    .word 0x006E1023              /* 1 sh      t1, 0(t3) */
    .word 0x006E0023              /* 2 sb      t1, 0(t3) */
    .word 0x086E202F              /* 3 amoswap.w x0, t1, (t3) */
    .word 0x006E202F              /* 4 amoadd.w  x0, t1, (t3) */
    .word 0x186E2EAF              /* 5 sc.w    t4, t1, (t3) */
    .word 0x186E2EAF              /* 6 sc.w    t4, t1, (t3) (no reservation for t3) */
