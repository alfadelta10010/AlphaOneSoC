# LR/SC and AMO aimed at the CLINT. A reservation needs a reservation set,
# which an IO window has none of: expect cause 5 then 7, AMO succeeding.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   s0, 0
    li   a0, 0x02004000
    li   a1, 0
    li   a2, 0
    li   a3, 0
    lr.w  a1, (a0)
    li    t0, 1
    sc.w  a2, t0, (a0)
    li    t0, 0
    amoadd.w a3, t0, (a0)
    mv   a4, s0                # expect 0x57
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
