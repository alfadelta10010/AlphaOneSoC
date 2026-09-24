# A fetch that faults at an address the memory aliases onto a real MRET word.
# 0x40000000 is unmapped in both models and the sim memory masks addr[24:0].
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   t1, 0x80              # MPIE=1, MIE=0, MPP=00 (U)
    csrw mstatus, t1
    la   t1, mret_word
    li   t2, 0x80000000
    sub  t1, t1, t2
    li   t2, 0x40000000
    add  t1, t1, t2
    jr   t1
.balign 4
handler:
    csrr a2, mcause            # expect 1
    csrr a3, mtval
    csrr a0, mstatus           # expect 0x1800
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
1:  j 1b
.balign 4
mret_word:
    mret
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
