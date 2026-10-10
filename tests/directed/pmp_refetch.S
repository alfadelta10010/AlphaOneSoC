# Gap probe for the PMP-write refetch (ex_pmp_csr_wr). With a locked entry
# already present, M-mode fetches go through the fetch-PMP phase. A write that
# adds a locked, non-executable NA4 entry over the very next instruction must
# make that instruction fault (cause 1, mtval = its address). Without the
# refetch its fetch verdict is latched in the CSR-write stall cycle, against
# the old configuration, and it executes.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   s0, 0
    li   s1, 0
    li   a1, 0
    la   t0, target
    srli t0, t0, 2
    csrw pmpaddr1, t0
    li   t0, 0x203C0000        # entry 0: NA4 at 0x80F00000, L, R (never touched)
    csrw pmpaddr0, t0
    li   t0, 0x91
    csrw pmpcfg0, t0           # a lock exists from here on
    nop
    li   t0, 0x9191            # entry 1: NA4 over `target`, L, R only (no X)
    csrw pmpcfg0, t0
target:
    addi a1, a1, 1             # must not execute: cause 1, mtval = target
    addi a2, a1, 7
    mv   a3, s0                # expect 1
    mv   a4, s1                # expect &target
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
1:  j 1b
.balign 4
handler:
    csrr s0, mcause
    csrr s1, mtval
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
