# Gap probe for the PMP-write refetch (ex_pmp_csr_wr). With a locked entry
# already present, M-mode fetches go through the fetch-PMP phase. A write that
# adds a locked, non-executable NAPOT entry (4 KiB: the grain) over the very next instruction must
# make that instruction fault (cause 1, mtval = its address). Without the
# refetch its fetch verdict is latched in the CSR-write stall cycle, against
# the old configuration, and it executes.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
  csrw pmpcfg0, zero          # Spike resets pmpcfg0 to NAPOT RWX, the core to OFF: start both from OFF (a pmpaddr write is logged as read back)
    la   t6, handler
    csrw mtvec, t6
    li   s0, 0
    li   s1, 0
    li   a1, 0
    la   t0, target
    srli t0, t0, 2
    ori  t0, t0, 0x1ff         # NAPOT 4 KiB over the page of `target` (the grain; no NA4)
    csrw pmpaddr1, t0
    li   t0, 0x203C01FF        # entry 0: NAPOT 4 KiB at 0x80F00000, L, R (never touched)
    csrw pmpaddr0, t0
    li   t0, 0x99
    csrw pmpcfg0, t0           # a lock exists from here on
    nop
    li   t0, 0x9999            # entry 1: NAPOT over the page of `target`, L, R only (no X)
    la   t6, pre
    jr   t6
    # `target` has to start a 4 KiB page, with the pmpcfg0 write the last
    # instruction of the page before it.
    .section .text.pg,"ax",@progbits
    .balign 4096
    .skip 4092
pre:
    csrw pmpcfg0, t0
target:
    addi a1, a1, 1             # must not execute: cause 1, mtval = target
    .skip 4092
cont:                          # the handler returns here, in the next page
    addi a2, a1, 7
    mv   a3, s0                # expect 1
    mv   a4, s1                # expect &target
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
1:  j 1b
    .section .text.init
.balign 4
handler:
    csrr s0, mcause
    csrr s1, mtval
    la   t2, cont
    csrw mepc, t2
    mret
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
