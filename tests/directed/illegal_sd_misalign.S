# Exception priority: an illegal encoding that also has a bad address.
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   a0, 0x80800001
    .word 0x00b53023
    li   a4, 0x0000c0de
    j    done
.balign 4
handler:
    csrr a2, mcause
    csrr a3, mtval
done:
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
