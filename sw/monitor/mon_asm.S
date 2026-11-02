/* AlphaOne monitor, assembly side: trap entry and exit, accesses that may
 * fault, and two demo programs. The frame layout is struct frame in
 * monitor.c: x0..x31 at 4*n, then mepc, mstatus, mcause, mtval. */
#define F_MEPC     128
#define F_MSTATUS  132
#define F_MCAUSE   136
#define F_MTVAL    140

    .section .text
    .align 2

/* mscratch is 0 while the monitor runs and points at the frame while a
 * program runs. A trap from a program swaps sp with it and saves the
 * program's registers; a trap from the monitor itself (a probe) swaps back
 * and goes to the probe's resume point. */
    .globl mon_trap_entry
mon_trap_entry:
    csrrw   sp, mscratch, sp
    bnez    sp, 1f
    csrrw   sp, mscratch, sp
    la      t0, mon_probe_resume
    lw      t0, 0(t0)
    beqz    t0, 9f
    csrw    mepc, t0
    mret
9:  call    mon_fatal
1:  .irp n,1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    sw      x\n, 4*\n(sp)
    .endr
    csrr    t0, mscratch
    sw      t0, 8(sp)
    csrw    mscratch, zero
    sw      zero, 0(sp)
    csrr    t0, mepc
    sw      t0, F_MEPC(sp)
    csrr    t0, mstatus
    sw      t0, F_MSTATUS(sp)
    csrr    t0, mcause
    sw      t0, F_MCAUSE(sp)
    csrr    t0, mtval
    sw      t0, F_MTVAL(sp)
    mv      a0, sp
    call    mon_trap
2:  j       2b

/* void mon_resume(struct frame *f): load every register from the frame and
 * return from the trap. Does not return. */
    .globl mon_resume
mon_resume:
    csrw    mscratch, a0
    lw      t0, F_MEPC(a0)
    csrw    mepc, t0
    mv      sp, a0
    .irp n,1,3,4,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    lw      x\n, 4*\n(sp)
    .endr
    lw      x5, 20(sp)
    lw      sp, 8(sp)
    mret

/* void mon_switch_stack(void *sp, void (*fn)(void)) */
    .globl mon_switch_stack
mon_switch_stack:
    mv      sp, a0
    jr      a1

/* int mon_probe(void *fn, uint32_t a0, uint32_t a1, uint32_t *out)
 * Calls fn(a0, a1) with a trap redirected to mon_probe_fault. Returns 0 and
 * stores fn's result in *out, or returns 1 if fn trapped. */
    .globl mon_probe
mon_probe:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      a3, 8(sp)
    la      t0, mon_probe_sp
    sw      sp, 0(t0)
    la      t0, mon_probe_fault
    la      t1, mon_probe_resume
    sw      t0, 0(t1)
    mv      t1, a0
    mv      a0, a1
    mv      a1, a2
    jalr    t1
    la      t1, mon_probe_resume
    sw      zero, 0(t1)
    lw      a3, 8(sp)
    sw      a0, 0(a3)
    li      a0, 0
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
mon_probe_fault:
    la      t1, mon_probe_resume
    sw      zero, 0(t1)
    la      t0, mon_probe_sp
    lw      sp, 0(t0)
    lw      ra, 12(sp)
    li      a0, 1
    addi    sp, sp, 16
    ret

    .globl mon_lw, mon_lh, mon_lb, mon_sw, mon_sh, mon_sb
mon_lw: lw      a0, 0(a0)
        ret
mon_lh: lhu     a0, 0(a0)
        ret
mon_lb: lbu     a0, 0(a0)
        ret
mon_sw: sw      a1, 0(a0)
        ret
mon_sh: sh      a1, 0(a0)
        ret
mon_sb: sb      a1, 0(a0)
        ret

/* A program that returns lands here. */
    .globl mon_return
mon_return:
    ebreak

/* Demos, run with `g`: demo_regs loads a known value in every register but
 * sp (0xA5A50000 + n in xn) and stops; demo_spin counts in a0 until Ctrl-C
 * (gb) breaks in. */
    .globl demo_regs
demo_regs:
    .irp n,1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\n, 0xA5A50000 + \n
    .endr
    ebreak

    .globl demo_spin
demo_spin:
    li      a0, 0
1:  addi    a0, a0, 1
    j       1b

    .section .bss
    .align 2
    .globl mon_probe_resume, mon_probe_sp
mon_probe_resume: .space 4
mon_probe_sp:     .space 4
