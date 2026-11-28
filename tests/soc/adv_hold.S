/* Track B adversarial review (2026-11-22): the core's fetch hold (WO-76: a fetch that completes while the
 * pipeline is stalled is kept in if_kbuf/if_wlo and consumed when IF/EX moves) at SoC level, with the real
 * cache, mem_ctrl and QSPI engine. tb/tb_adv.v; build -DCMODE=0/1/2; signature must be the same in all three
 * AND equal to tests/soc/adv_hold_ref.py's value for the same SEED/NK (absolute oracle, written from the
 * RISC-V M/A/Zicsr semantics, not from the RTL).
 *
 * Spec basis: WO-76 sections 2-3 (H3: hold set on a stalled completion with no data access in WB, cleared on
 * every !stall edge; nothing architectural changes), the RISC-V unprivileged spec (M: div/rem by zero and
 * overflow results; A: amoadd, LR/SC), privileged spec (timer interrupt, WFI, MRET).
 *
 * The kernel (position independent, k_start..k_end) runs NK iterations of: two LFSR operands (one in 8 sets
 * b = 0, one in 8 sets a = 0x80000000, b = -1), every M op and the three register shifts (serial in the
 * core), each followed by a 32-bit or compressed instruction (so the held word is aligned, straddling or a
 * compressed pair), a store/load pair, amoadd.w, an LR/SC retry loop, mscratch write/read, a pmpaddr0 write
 * (an ex_nofetch instruction), and every 8th iteration a WFI followed by a compressed instruction. It is run
 * from flash, from PSRAM at a word address and from PSRAM at a halfword address (every 32-bit instruction
 * flips between aligned and straddling). Machine timer interrupts: every iteration re-arms mtimecmp 0..1023
 * clocks ahead (its own LCG in s6, an extra MUL), so interrupts land on every kind of stall, including those
 * with a held word; the WFI re-arms 300..555 clocks ahead first. The handler re-arms 4000 clocks ahead (longer
 * than the handler in every mode: no livelock, and a backstop wake for the WFI) and keeps every kernel
 * register. FAIL 0x71 if fewer than 20 interrupts were taken (scenario not reached), 0x7E on any other trap
 * (value = mcause, value2 = mepc).
 */
#include "adv.h"

#ifndef NK
#define NK 24
#endif
#ifndef SEED
#define SEED 0x2468ACE1
#endif
#define BUF   0x80050100
#define STK   0x80050000
#define KA    0x80040000
#define KB    0x80042002

    .section .text.init
    .globl _start
_start:
    ADV_ENTRY trap
    li   sp, STK
    li   s5, BUF
    sw   zero, 0(s5)
    sw   zero, 4(s5)
    li   s4, SEED
    li   a3, 0
    li   s6, 0x13579BDF           /* the interrupt-delay LCG */
    li   s7, 0                    /* interrupts taken */

    /* copy the kernel to KA and KB (halfwords: KB is not word aligned) */
    li   a1, KA
    jal  kcopy
    li   a1, KB
    jal  kcopy
    fence.i

    /* timer: mtimecmp = mtime + 200, MTIE, MIE */
    li   t0, MTIMECMP
    sw   zero, 4(t0)
    li   t1, MTIME
    lw   t2, 0(t1)
    addi t2, t2, 200
    sw   t2, 0(t0)
    li   t0, 0x80
    csrs mie, t0
    csrsi mstatus, 8

    li   a0, NK
    call k_start                  /* from flash */
    SIGF a3
    li   a0, NK
    li   t0, KA
    jalr ra, 0(t0)                /* from PSRAM, word aligned */
    SIGF a3
    li   a0, NK
    li   t0, KB
    jalr ra, 0(t0)                /* from PSRAM, halfword aligned */
    SIGF a3

    csrci mstatus, 8
    li   t0, 0x80
    csrc mie, t0
    lw   t1, 4(s5)
    SIGF t1
    li   t0, 20
    bgeu s7, t0, 1f
    mv   a7, s7
    li   a6, 0x71
    j    test_fail
1:  sw   s7, MB_SPARE(s11)
    ADV_PASS

kcopy:                            /* a1 = destination; clobbers t0-t2 */
    la   t0, k_start
    la   t2, k_end
1:  lhu  t1, 0(t0)
    sh   t1, 0(a1)
    addi t0, t0, 2
    addi a1, a1, 2
    bltu t0, t2, 1b
    ret

    .balign 4
trap:
    sw   t0, 0(sp)
    sw   t1, 4(sp)
    sw   t2, 8(sp)
    csrr t0, mcause
    li   t1, 0x80000007
    bne  t0, t1, bad_trap
    addi s7, s7, 1
    li   t0, MTIME
    lw   t1, 0(t0)
    li   t2, 4000
    add  t1, t1, t2
    li   t0, MTIMECMP
    sw   t1, 0(t0)
    lw   t0, 0(sp)
    lw   t1, 4(sp)
    lw   t2, 8(sp)
    mret
bad_trap:
    csrr a7, mcause
    csrr t0, mepc
    li   s11, SYSCON
    sw   t0, MB_VALUE2(s11)
    li   a6, 0x7E
    slli a6, a6, 16
    li   t0, FINISH_FAIL
    or   a6, a6, t0
    sw   a7, MB_VALUE(s11)
    sw   a6, MB_FINISH(s11)
1:  j    1b

    ADV_FAIL_BODY

/* ── the kernel: a0 = iterations; uses a2 a3 a4 s4 s5 t0-t3 t5 a5 ───────── */
    .balign 4
k_start:
    .option push
    .option norvc
    .option norelax
1:  li     t0, MTIME              /* re-arm the timer 0..1023 clocks ahead */
    lw     t1, 0(t0)
    li     t2, 1103515245
    mul    s6, s6, t2
    addi   s6, s6, 1234
    andi   t2, s6, 0x3FF
    add    t1, t1, t2
    li     t0, MTIMECMP
    sw     t1, 0(t0)
    LFSR
    mv     a2, s4
    LFSR
    mv     a4, s4
    andi   t0, s4, 0x70
    bnez   t0, 2f
    li     a4, 0
2:  li     t1, 0x10
    bne    t0, t1, 3f
    lui    a2, 0x80000
    li     a4, -1
3:  mul    t0, a2, a4
    add    a3, a3, t0
    mulh   t1, a2, a4
    .option rvc
    c.add  a3, t1
    c.slli a3, 1
    .option norvc
    mulhsu t0, a2, a4
    .option rvc
    c.add  a3, t0
    .option norvc
    xor    a3, a3, a2
    mulhu  t1, a2, a4
    xor    a3, a3, t1
    div    t0, a2, a4
    .option rvc
    c.add  a3, t0
    .option norvc
    divu   t1, a2, a4
    add    a3, a3, t1
    rem    t0, a2, a4
    .option rvc
    c.slli a3, 3
    .option norvc
    xor    a3, a3, t0
    remu   t1, a2, a4
    .option rvc
    c.add  a3, t1
    .option norvc
    sll    t0, a2, a4
    .option rvc
    c.add  a3, t0
    .option norvc
    srl    t1, a2, a4
    xor    a3, a3, t1
    sra    t0, a2, a4
    .option rvc
    c.add  a3, t0
    .option norvc
    sw     a3, 0(s5)
    lw     t1, 4(s5)
    add    t1, t1, a2
    sw     t1, 4(s5)
    amoadd.w t0, a4, (s5)
    .option rvc
    c.add  a3, t0
    .option norvc
4:  lr.w   t0, (s5)
    add    t2, t0, a2
    sc.w   t3, t2, (s5)
    bnez   t3, 4b
    lw     t1, 0(s5)
    xor    a3, a3, t1
    csrw   mscratch, a3
    csrr   t1, mscratch
    .option rvc
    c.add  a3, t1
    .option norvc
    csrw   pmpaddr0, a2
    andi   t0, a0, 7
    li     t1, 3
    bne    t0, t1, 5f
    li     t0, MTIME              /* the WFI's wake: 300..555 clocks ahead */
    lw     t1, 0(t0)
    andi   t2, s6, 0xFF
    add    t1, t1, t2
    addi   t1, t1, 300
    li     t0, MTIMECMP
    sw     t1, 0(t0)
    wfi
    .option rvc
    c.addi a3, 1
    .option norvc
5:
    .option rvc
    c.addi a0, -1
    .option norvc
    bnez   a0, 1b
    ret
    .option pop
    .balign 4
k_end:
