# AMOs, LR and SC whose destination is also a source: rd == rs2, rd == rs1
# (the address register) and rd == rs1 == rs2, for all nine AMOs. The
# register file reads synchronously and write-first, so a pipeline that read
# an operand again after the instruction had written rd would get the new
# value: KianV's sky25b FSM did that, and every AMO with rd == rs2 broke
# (268 of them in a Linux Image). Every result is read at once by the next
# instruction on both ports, and again two instructions later, so the AMO's
# phase-1 write meets the WB->EX forwarding and then the next read's capture
# edge. The last block chains AMOs through rd -> rs2.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   s0, buf
    li   s1, 0x80000001          # memory before each AMO: negative, odd
    li   s2, 0x0f0f00f0          # operand

# AMO3 op: the three aliasings of one AMO, each starting from mem = s1.
.macro AMO3 op
    sw   s1, 0(s0)
    mv   a1, s2
    \op  a1, a1, (s0)            # rd == rs2: a1 = old, mem = op(old, s2)
    add  a2, a1, a1              # the result, on both ports, at once
    lw   a3, 0(s0)
    xor  a4, a1, a3              # ...and two instructions later
    sw   s1, 0(s0)
    mv   a5, s0
    \op  a5, s2, (a5)            # rd == rs1: the address register gets the old value
    sub  a6, a5, s2
    lw   a7, 0(s0)
    or   t0, a5, a7
    sw   s1, 0(s0)
    mv   t1, s0
    \op  t1, t1, (t1)            # rd == rs1 == rs2: the operand is the address
    and  t2, t1, t1
    lw   t3, 0(s0)
    add  t4, t1, t3
.endm

    AMO3 amoswap.w
    AMO3 amoadd.w
    AMO3 amoxor.w
    AMO3 amoand.w
    AMO3 amoor.w
    AMO3 amomin.w
    AMO3 amomax.w
    AMO3 amominu.w
    AMO3 amomaxu.w

# LR with rd == rs1; SC with rd == rs2, rd == rs1, rd == rs1 == rs2, each
# succeeding (a reservation from the LR before it) and then failing (none).
    sw   s1, 0(s0)
    mv   a0, s0
    lr.w a0, (a0)                # rd == rs1: a0 = mem
    add  a1, a0, a0
    lr.w t5, (s0)
    mv   a2, s2
    sc.w a2, a2, (s0)            # rd == rs2: succeeds, a2 = 0, mem = s2
    add  a3, a2, a2
    lw   a4, 0(s0)
    sc.w a2, s1, (s0)            # no reservation: fails, a2 = 1, mem kept
    lw   a5, 0(s0)
    add  a6, a2, a5
    lr.w t5, (s0)
    mv   a7, s0
    sc.w a7, s1, (a7)            # rd == rs1: succeeds, a7 = 0, mem = s1
    addi t0, a7, 5
    lw   t1, 0(s0)
    lr.w t5, (s0)
    mv   t2, s0
    sc.w t2, t2, (t2)            # rd == rs1 == rs2: stores the address, t2 = 0
    add  t3, t2, t2
    lw   t4, 0(s0)
    mv   t2, s0
    sc.w t2, t2, (t2)            # again with no reservation: fails, t2 = 1
    add  t3, t2, t2
    lw   t4, 0(s0)

# A chain: each AMO's old value is the next one's operand (rd -> rs2 at once),
# with rd == rs2 throughout.
    sw   s1, 0(s0)
    li   a0, 3
    amoadd.w a0, a0, (s0)
    amoxor.w a0, a0, (s0)
    amomaxu.w a0, a0, (s0)
    amoswap.w a0, a0, (s0)
    amomin.w a0, a0, (s0)
    lw   a1, 0(s0)
    add  a2, a0, a1

    li   t5, 1
    la   t6, tohost
    sw   t5, 0(t6)
1:  j 1b

.section .data
.balign 16
buf: .word 0, 0, 0, 0
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
