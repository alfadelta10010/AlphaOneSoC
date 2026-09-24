# MPRV with an explicit unlocked PMP entry, so the result does not depend on
# either model's PMP reset value.
# Entry 0: NA4 @0x81000000, no R/W/X, L=0. M-mode bypasses an unlocked entry;
# U-mode does not. So with MPRV=1 and MPP=U an M-mode access must fault.
# Expect a1=0x11, a2=0x11, a4=0x75 (store fault 7 then load fault 5).
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   s0, 0
    li   a0, 0x81000000
    li   t0, 0x11
    sw   t0, 0(a0)

    li   t0, 0x20400000        # 0x81000000 >> 2
    csrw pmpaddr0, t0
    li   t0, 0x10              # A=NA4, no permissions, unlocked
    csrw pmpcfg0, t0

    lw   a1, 0(a0)             # M-mode, MPRV=0 -> allowed

    li   t0, 0x00020000        # MPRV=1, MPP=00 (U)
    csrw mstatus, t0
    li   t1, 0x22
    sw   t1, 0(a0)             # -> store access fault (7)
    lw   t2, 0(a0)             # -> load access fault (5)

    csrw mstatus, x0           # MPRV=0; the NEXT instruction must see it
    lw   a2, 0(a0)             # -> allowed, still 0x11

    mv   a4, s0
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
1:  j 1b
.balign 4
handler:
    csrr t3, mcause
    slli s0, s0, 4
    or   s0, s0, t3
    csrr t3, mepc
    addi t3, t3, 4
    csrw mepc, t3
    mret
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
