# Compressed load with misa.C=0 at a misaligned address. The encoding is
# illegal (C is off) AND the expanded lw is misaligned, so it exercises the
# cause-2-vs-cause-4 priority with a memory op the controller legitimately
# asserts memRD for.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   a0, 0x80800001
    csrci misa, 4
    nop
    nop
    .half 0x4108               # c.lw a0, 0(a0)
    .half 0x0001
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
