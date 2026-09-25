# MRET while the pipeline is stalled. $2 supplies the stall source.
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   t0, 0x81000000
    li   t1, 0x1800           # MPP=M, MPIE=0, MIE=0
    csrw mstatus, t1
    la   t2, after
    csrw mepc, t2
    li   t3, 5
    nop
    nop
    mret
after:
    csrr a0, mstatus          # expect 0x00000080
    li   a1, 0x0000aaaa
    j    done
.balign 4
handler:
    csrr a2, mcause
    li   a3, 0x0000dead
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
