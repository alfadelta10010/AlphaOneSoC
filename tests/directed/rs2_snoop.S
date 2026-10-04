# Gap probe for rs2_hold's snoop: the instruction right behind a load, an AMO
# or an SC reads that instruction's rd as its rs2, while the older one is
# still in WB (held by wb_mem_stall, or an AMO's two-phase WB at any wait).
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   s0, buf
    li   t0, 0x11111111
    li   t1, 0x22222222
    li   a0, 3
    li   a1, 5
    li   a2, 7
    li   a5, 0
    lw   t0, 0(s0)          # load -> store data
    sw   t0, 8(s0)
    lw   t1, 4(s0)          # load -> R-type rs2
    add  a3, a0, t1
    lw   a1, 0(s0)          # load -> branch rs2
    beq  a0, a1, 1f
    addi a5, a5, 1
1:  amoadd.w a2, a0, (s0)   # AMO -> R-type rs2 (rd written in AMO phase 1)
    add  a4, a0, a2
    amoswap.w a2, a1, (s0)  # AMO -> store data
    sw   a2, 12(s0)
    lr.w t2, (s0)
    sc.w a0, a1, (s0)       # SC -> R-type rs2 (success: 0)
    add  a3, a3, a0
    lw   t1, 4(s0)          # load -> M op rs2
    mul  a4, a4, t1
    lw   t1, 0(s0)          # load -> shift amount
    sll  a5, a5, t1
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
2:  j 2b
.section .data
.balign 16
buf: .word 0x00000003, 0x00000009, 0, 0
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
