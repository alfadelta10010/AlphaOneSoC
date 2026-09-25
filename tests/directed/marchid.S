.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
    csrr a0, marchid
    csrr a1, mvendorid
    csrr a2, mimpid
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
1:  j 1b
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
