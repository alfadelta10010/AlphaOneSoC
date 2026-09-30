# LR/SC reservation policy matrix. a0..a4 = SC result (0 success, 1 fail).
# 1 lr; sw same addr; sc        -> succeed (own stores keep the reservation)
# 2 lr; amoadd same addr; sc    -> succeed (so do own AMOs)
# 3 lr; ecall; sc               -> fail    (trap clear)
# 4 lr; sc unrelated; sc        -> fail    (any SC invalidates, success or not)
# 5 lr; sc                      -> succeed (control)
# Spike makes the same five choices, so the whole trace is compared.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   s0, 0x80800000
    li   s1, 0x80800010

    sw   x0, 0(s0)
    lr.w t0, (s0)
    li   t1, 0x11
    sw   t1, 0(s0)
    li   t1, 0x22
    sc.w a0, t1, (s0)

    sw   x0, 0(s0)
    lr.w t0, (s0)
    li   t1, 1
    amoadd.w t2, t1, (s0)
    li   t1, 0x33
    sc.w a1, t1, (s0)

    sw   x0, 0(s0)
    lr.w t0, (s0)
    ecall
    li   t1, 0x44
    sc.w a2, t1, (s0)

    sw   x0, 0(s0)
    lr.w t0, (s0)
    li   t1, 0x55
    sc.w t3, t1, (s1)
    li   t1, 0x66
    sc.w a3, t1, (s0)

    sw   x0, 0(s0)
    lr.w t0, (s0)
    li   t1, 0x77
    sc.w a4, t1, (s0)

    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
1:  j 1b
.balign 4
handler:
    csrr t5, mepc
    addi t5, t5, 4
    csrw mepc, t5
    mret
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
