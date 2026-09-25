# MPRV: with MPRV=1 and MPP=U, an M-mode load/store must be PMP-checked as
# U-mode. With no PMP entry granting U access, that means it faults -- and the
# instruction fetch must NOT be affected, since the spec excludes fetch.
# Also checks MRET clears MPRV when returning below M.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   s0, 0                 # cause log
    # An explicit unlocked entry with no permissions over everything: M-mode
    # bypasses it, U-mode is denied. This is what the spec's PMP reset gives
    # the core anyway, but Spike resets permissive (pmpcfg0 0x1f, pmpaddr0
    # ~0), so without it the two models disagree for a reason unrelated to
    # MPRV.
    li   t0, -1
    csrw pmpaddr0, t0
    li   t0, 0x18              # A=NAPOT, RWX=000, L=0
    csrw pmpcfg0, t0
    li   a0, 0x80800000
    sw   x0, 0(a0)

    # baseline: M-mode store with MPRV=0 must succeed
    li   t0, 0x11
    sw   t0, 0(a0)
    lw   a1, 0(a0)             # expect 0x11

    # MPRV=1, MPP=U -> data accesses check as U-mode -> no PMP entry -> fault
    li   t0, 0x00020000        # MPRV, MPP=00 (U)
    csrw mstatus, t0
    li   t0, 0x22
    sw   t0, 0(a0)             # expect store access fault (7)
    csrw mstatus, x0           # back to MPRV=0
    lw   a2, 0(a0)             # expect still 0x11 (the store faulted)

    # MRET must clear MPRV when returning below M
    li   t0, 0x00020000        # MPRV=1, MPP=00 (U) -> return to U
    csrw mstatus, t0
    la   t1, umode
    csrw mepc, t1
    # grant U access to everything first so U-mode can run at all
    li   t0, -1
    csrw pmpaddr0, t0
    li   t0, 0x1f              # NAPOT, RWX
    csrw pmpcfg0, t0
    mret
umode:
    ecall                      # -> cause 8, handler reads mstatus
done:
    mv   a4, s0
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
1:  j 1b
.balign 4
handler:
    csrr t1, mcause
    slli s0, s0, 4
    or   s0, s0, t1
    csrr a3, mstatus           # last write wins: mstatus at the ecall trap
    li   t2, 8
    beq  t1, t2, go_done
    csrr t2, mepc
    addi t2, t2, 4
    csrw mepc, t2
    mret
go_done:
    la   t2, done
    csrw mepc, t2
    li   t2, 0x1800
    csrw mstatus, t2
    mret
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
