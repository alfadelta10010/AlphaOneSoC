/* Track B adversarial review (2026-11-22): the 256 B instruction cache (WO-77, 8 x 32 B lines in 16 B sectors since
 * WO-cache832, sector addr[7:4], sectors 0-7 in data_mem, 8-15 in data_hi) and the core's fetch hold (WO-76) under stores, FENCE.I and
 * CACHE_CTL writes that land while a line of either macro is being filled. tb/tb_adv.v; build -DCMODE=0/1/2
 * (cache off, EN, EN+PBURST): the signature must be the same in all three.
 *
 * Spec basis: WO-77 sections 1-2 (geometry, two macros, per-port select for straddles across lines 7->8 and
 * 15->0); docs/pins-and-peripherals.md 12 (stores, AMOs and SCs invalidate their line, no flush needed;
 * FENCE.I flushes; EN 1->0 and 0->1 at any time); RISC-V Zifencei.
 *
 * Part A, aliasing and capacity. 32 one-sector functions: P sector j (j = 0..15) at PA + 16 j adds j + 1 to a0,
 * Q sector j at PA + 0x100 + 16 j (same index, other tag) adds (j + 1) << 5. NCALL calls to random cells
 * (LFSR): a0 must equal the independently computed sum after every call (fail 0x11). Sectors j and j + 8 have
 * the same tag, so a cache that drops index[3] returns the other macro's line. Then (cache on only) the
 * capacity check: 8 sweeps over P sectors 3..15 from a caller that sits in sectors 0-2 (.balign 256), timed with
 * mcycle, cache on vs. EN = 0; on 256 B every call hits, on 128 B lines j and j + 8 evict each other:
 * EXPECTED 3 t_on < t_off (fail 0x61, value t_on, value2 t_off).
 *
 * Part B, the straddle / store / FENCE.I / EN matrix. A 160-byte routine at S + 0x70 (S 256-aligned, PSRAM):
 *   0x70 sh t3,0(t2) (site 1, line 7)    0x74 +1   0x78 +2   0x7C c.addi a1,1
 *   0x7E +4  (32-bit, straddles line 7 -> 8: data_mem -> data_hi)
 *   0x82 sh t6,0(t4) (site 2, line 8)    0x86 +8   0x8A +0x10
 *   0x8E +0x20 (straddles line 8 -> 9)   0x92 c.addi a1,2   0x94 j 0xF0
 *   0xF0 sh s3,0(s2) (site 3, line 15)   0xF4 +0x40   0xF8 +0x80   0xFC c.addi a1,4
 *   0xFE +0x100 (straddles line 15 -> line 0 of the next 256 B: data_hi -> data_mem)
 *   0x102 +0x200   0x106 c.addi a1,8   0x108 ret
 * ("+v" = addi a0,a0,v). Unpatched: a0 = 0x3FF, a1 = 15. Every patch target is at least the third
 * instruction after its site, so the store has completed before the target is fetched (no "in flight"
 * allowance needed). Each table row: an optional pre-patch (a 32-bit word written with two sh, then
 * FENCE.I: used to plant a FENCE.I in the routine), and an (address, halfword) per site (a code halfword,
 * CACHE_CTL, or a dummy). KILL = rd x0 (the add disappears), HI(v) = the upper half of addi a0,a0,v.
 * Every row runs cold (FENCE.I, then the sites race the fills of lines 7, 8 and 15) and warm (one clean
 * call first: the stores hit valid lines of both macros). Calls 1 and 2 run with the sites armed; call 2
 * sees every patch. EXPECTED a0 = 0x3FF + the row's delta for that call, a1 = 15, CACHE_CTL = mode | 2
 * after the row. Fail codes: (row << 8) | (warm << 4) | call for a0, 0x0F for a1, 0x2F CACHE_CTL.
 */
#include "adv.h"

#ifndef NCALL
#define NCALL 400
#endif
#ifndef SEED
#define SEED 0x5EED0C25
#endif
#define PA    0x80020000
#define S     0x80030000
#define DUMMY 0x8000F000

#define KILL     0x0013                                  /* low half of addi x0,a0,v */
#define HI(v)    ((ADDI_A0(v) >> 16) & 0xFFFF)
#define FENCEI   0x0000100F
#define CV       CCTL_VAL

    .section .text.init
    .globl _start
_start:
    ADV_ENTRY trap

/* ── Part A ─────────────────────────────────────────────────────────────── */
    li   t0, PA
    li   t1, 0
1:  addi t2, t1, 1
    slli t2, t2, 20
    li   t3, 0x00050513
    or   t2, t2, t3
    sw   t2, 0(t0)                /* P line j: addi a0,a0,j+1 */
    addi t2, t1, 1
    slli t2, t2, 25
    or   t2, t2, t3
    sw   t2, 256(t0)              /* Q line j: addi a0,a0,(j+1)<<5 */
    li   t3, INSN_JR_RA
    sw   t3, 4(t0)
    sw   t3, 260(t0)
    li   t3, INSN_NOP
    sw   t3, 8(t0)
    sw   t3, 12(t0)
    sw   t3, 264(t0)
    sw   t3, 268(t0)
    addi t0, t0, 16
    addi t1, t1, 1
    li   t3, 16
    bne  t1, t3, 1b
    fence.i

    li   s4, SEED
    li   s0, NCALL
    li   a0, 0
    li   s1, 0
2:  LFSR
    andi s2, s4, 31               /* cell c: line c & 15 of P (c < 16) or Q */
    andi t2, s2, 15
    slli t2, t2, 4
    srli t3, s2, 4
    slli t3, t3, 8
    add  t2, t2, t3
    li   t3, PA
    add  t2, t2, t3
    jalr ra, 0(t2)
    andi t2, s2, 15
    addi t2, t2, 1
    srli t3, s2, 4
    beqz t3, 3f
    slli t2, t2, 5
3:  add  s1, s1, t2
    beq  a0, s1, 4f
    mv   a7, a0
    li   a6, 0x11
    j    test_fail
4:  SIGF a0
    addi s0, s0, -1
    bnez s0, 2b

#if CMODE != 0
    li   s5, CACHE_CTL
    li   a2, 1
    call tsweep                   /* warm */
    csrr s6, mcycle
    li   a2, 8
    call tsweep
    csrr s7, mcycle
    sub  s6, s7, s6               /* t_on */
    sw   zero, 0(s5)
    csrr s7, mcycle
    li   a2, 8
    call tsweep
    csrr s8, mcycle
    sub  s7, s8, s7               /* t_off */
    li   t0, CV
    sw   t0, 0(s5)
    slli t0, s6, 1
    add  t0, t0, s6
    bltu t0, s7, 5f
    sw   s7, MB_VALUE2(s11)
    mv   a7, s6
    li   a6, 0x61
    sw   a7, MB_SPARE(s11)
    j    test_fail
5:
#endif

/* ── Part B ─────────────────────────────────────────────────────────────── */
    la   s0, scen_tab
    li   s1, 1                    /* row number (1-based, for the fail code) */
    li   s7, 0                    /* 0 cold, 1 warm */
    li   s9, S + 0x70
row:
    lw   t0, 0(s0)
    li   t1, -1
    beq  t0, t1, part_b_done
    jal  restore
    lw   t0, 0(s0)
    beqz t0, 1f
    lw   t1, 4(s0)                /* pre-patch: 32-bit value at a halfword address */
    sh   t1, 0(t0)
    srli t1, t1, 16
    sh   t1, 2(t0)
    fence.i
1:  beqz s7, 2f
    li   t2, DUMMY
    li   t3, 0
    li   t4, DUMMY
    li   t6, 0
    li   s2, DUMMY
    li   s3, 0
    lw   s5, 32(s0)
    li   s6, 0
    jal  docall
2:  lw   t2, 8(s0)
    lw   t3, 12(s0)
    lw   t4, 16(s0)
    lw   t6, 20(s0)
    lw   s2, 24(s0)
    lw   s3, 28(s0)
    lw   s5, 36(s0)
    li   s6, 1
    jal  docall
    lw   s5, 40(s0)
    li   s6, 2
    jal  docall
    li   t0, CACHE_CTL
    lw   t1, 0(t0)
    li   t0, (CV | 2)
    beq  t0, t1, 3f
    mv   a7, t1
    li   a6, 0x2F
    j    test_fail
3:  xori s7, s7, 1
    bnez s7, row                  /* the same row warm */
    addi s0, s0, 44
    addi s1, s1, 1
    j    row
part_b_done:
    jal  restore
    ADV_PASS

/* one call of the routine; s5 = expected delta, s6 = call number, s8 = saved ra */
docall:
    mv   s8, ra
    li   a0, 0
    li   a1, 0
    jalr ra, 0(s9)
    li   t0, 0x3FF
    add  t0, t0, s5
    beq  a0, t0, 1f
    mv   a7, a0
    slli a6, s1, 8
    slli t0, s7, 4
    or   a6, a6, t0
    or   a6, a6, s6
    j    test_fail
1:  li   t0, 15
    beq  a1, t0, 2f
    mv   a7, a1
    li   a6, 0x0F
    j    test_fail
2:  SIGF a0
    SIGF a1
    jr   s8

/* copy the routine (template offsets 0x70..0x10F) to S + 0x70, then FENCE.I */
restore:
    la   t0, tmpl + 0x70
    li   t1, S + 0x70
    li   t2, 40
1:  lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -1
    bnez t2, 1b
    fence.i
    ret

    .balign 4
trap:
    csrr a7, mcause
    csrr t0, mepc
    sw   t0, MB_VALUE2(s11)
    li   a6, 0x7E
    li   s11, SYSCON
    slli a6, a6, 16
    li   t0, FINISH_FAIL
    or   a6, a6, t0
    sw   a7, MB_VALUE(s11)
    sw   a6, MB_FINISH(s11)
1:  j    1b

    ADV_FAIL_BODY

#if CMODE != 0
/* a2 sweeps over PA sectors 3..15; this code (44 B) lives in cache sectors 0-2 */
    .balign 256
tsweep:
    .option push
    .option norvc
    .option norelax
    mv   t6, ra
    li   t4, PA + 0x100
1:  li   t3, PA + 0x30
2:  jalr ra, 0(t3)
    addi t3, t3, 16
    bne  t3, t4, 2b
    addi a2, a2, -1
    bnez a2, 1b
    jr   t6
    .option pop
#endif

    .section .rodata
    .balign 4
/* pre_addr, pre_val, s1 addr, s1 half, s2 addr, s2 half, s3 addr, s3 half, d0 (warm-up), d1, d2 */
scen_tab:
    .word 0, 0,            S+0x7E, KILL,         DUMMY, 0,             DUMMY, 0,              0,      -4,     -4      /* 1: line 7 (data_mem) filling, its straddle half */
    .word 0, 0,            S+0x80, HI(-4),       DUMMY, 0,             DUMMY, 0,              0,      -8,     -8      /* 2: line 8 word 0 = the straddle's B half */
    .word 0, 0,            S+0xFE, KILL,         DUMMY, 0,             DUMMY, 0,              0,      -0x100, -0x100  /* 3 */
    .word 0, 0,            DUMMY, 0,             S+0x8E, KILL,         DUMMY, 0,              0,      -0x20,  -0x20   /* 4: line 8 (data_hi) filling */
    .word 0, 0,            DUMMY, 0,             S+0x90, HI(-0x20),    DUMMY, 0,              0,      -0x40,  -0x40   /* 5: line 9 */
    .word 0, 0,            DUMMY, 0,             S+0x7E, KILL,         DUMMY, 0,              0,      0,      -4      /* 6: data_mem line 7 during the data_hi fill */
    .word 0, 0,            DUMMY, 0,             DUMMY, 0,             S+0xFE, KILL,          0,      -0x100, -0x100  /* 7: line 15 (data_hi) filling */
    .word 0, 0,            DUMMY, 0,             DUMMY, 0,             S+0x100, HI(-0x100),   0,      -0x200, -0x200  /* 8: line 0' (data_mem) = 15->0 B half */
    .word 0, 0,            DUMMY, 0,             DUMMY, 0,             S+0x104, HI(-0x200),   0,      -0x400, -0x400  /* 9 */
    .word 0, 0,            DUMMY, 0,             DUMMY, 0,             S+0x86, KILL,          0,      0,      -8      /* 10 */
    .word S+0x74, FENCEI,  DUMMY, 0,             DUMMY, 0,             DUMMY, 0,              -1,     -1,     -1      /* 11: FENCE.I in line 7 while it fills */
    .word S+0x86, FENCEI,  DUMMY, 0,             DUMMY, 0,             DUMMY, 0,              -8,     -8,     -8      /* 12: FENCE.I (pc[1] = 1) in line 8 */
    .word S+0xF8, FENCEI,  DUMMY, 0,             DUMMY, 0,             DUMMY, 0,              -0x80,  -0x80,  -0x80   /* 13: line 15 */
    .word S+0xFE, FENCEI,  DUMMY, 0,             DUMMY, 0,             DUMMY, 0,              -0x100, -0x100, -0x100  /* 14: FENCE.I straddling 15 -> 0' */
    .word 0, 0,            CACHE_CTL, 0,         CACHE_CTL, CV,        DUMMY, 0,              0,      0,      0       /* 15: EN off during the line 7 fill, on in line 8 */
    .word 0, 0,            DUMMY, 0,             CACHE_CTL, 0,         CACHE_CTL, CV,         0,      0,      0       /* 16 */
    .word 0, 0,            CACHE_CTL, 0,         DUMMY, 0,             CACHE_CTL, CV,         0,      0,      0       /* 17 */
    .word S+0x86, FENCEI,  S+0x90, HI(-0x20),    DUMMY, 0,             DUMMY, 0,              -8,     -0x48,  -0x48   /* 18 */
    .word 0, 0,            CACHE_CTL, 0,         S+0x8E, KILL,         CACHE_CTL, CV,         0,      -0x20,  -0x20   /* 19: EN off + dead data_hi fill */
    .word 0, 0,            S+0x7E, KILL,         S+0x8E, KILL,         S+0xFE, KILL,          0,      -0x124, -0x124  /* 20: all three fills dead */
    .word -1

/* the routine, copied to S (offsets as in the header) */
    .balign 4
tmpl:
    .option push
    .option norvc
    .option norelax
    .skip 0x70
    sh   t3, 0(t2)
    addi a0, a0, 1
    addi a0, a0, 2
    .half 0x0585                  /* c.addi a1, 1 */
    addi a0, a0, 4                /* 0x7E */
    sh   t6, 0(t4)                /* 0x82 */
    addi a0, a0, 8
    addi a0, a0, 0x10
    addi a0, a0, 0x20             /* 0x8E */
    .half 0x0589                  /* c.addi a1, 2 */
    .word 0x05C0006F              /* 0x94: jal x0, +0x5C (0xF0) */
    .skip 0xF0 - 0x98
    sh   s3, 0(s2)                /* 0xF0 */
    addi a0, a0, 0x40
    addi a0, a0, 0x80
    .half 0x0591                  /* c.addi a1, 4 */
    addi a0, a0, 0x100            /* 0xFE */
    addi a0, a0, 0x200            /* 0x102 */
    .half 0x05A1                  /* c.addi a1, 8 */
    jalr x0, 0(ra)                /* 0x108 */
    .word 0
    .if (. - tmpl) != 0x110
    .error "adv_c256: routine layout"
    .endif
    .option pop
