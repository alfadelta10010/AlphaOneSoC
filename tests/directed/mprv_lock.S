# Gap probe: M-mode, MPRV=1, MPP=U, and a LOCKED PMP entry elsewhere.
# The lock makes every M-mode fetch go through the time-shared checker's fetch
# phase. The fetch must be checked at priv_mode (M: no match -> allowed); only
# the data access takes MPP (U: no match -> load access fault, cause 5).
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   s0, 0
    li   a0, 0x80800000
    li   t0, 0x11
    sw   t0, 0(a0)
    li   t0, 0x203C0000        # NA4 at 0x80F00000 (never touched)
    csrw pmpaddr0, t0
    li   t0, 0x91              # L=1, A=NA4, R
    csrw pmpcfg0, t0
    li   t0, 0x00020000        # MPRV=1, MPP=U
    csrw mstatus, t0
    nop
    lw   a1, 0(a0)             # data as U: no matching entry -> cause 5
    addi a2, zero, 7           # the fetch stream itself keeps running at M
    csrw mstatus, x0
    lw   a3, 0(a0)             # 0x11
    mv   a4, s0                # expect 0x5
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
1:  j 1b
.balign 4
handler:
    csrr t1, mcause
    slli s0, s0, 4
    or   s0, s0, t1
    csrr t2, mepc
    addi t2, t2, 4
    csrw mepc, t2
    mret
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
