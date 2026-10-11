# Loads whose destination is their own base register (lw/lh/lhu/lb/lbu,
# c.lw, c.lwsp into sp), a pointer chase that uses each loaded value as the
# next base at once, and stores whose data register is the base. The base is
# read in EX before the load leaves it, and the load writes it from WB: the
# register file reads synchronously and write-first, so the instruction
# behind a load must take the loaded value (load-use stall, then the capture
# edge of the write), never the address it was loaded from.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   s0, chain
    mv   a0, s0
    lw   a0, 0(a0)               # rd == base: a0 = &chain[1]
    lw   a0, 0(a0)               # chase at once: a0 = &chain[2]
    lw   a0, 4(a0)               # a0 = chain[3] = &chain[0]
    add  a1, a0, a0
    lw   a0, 0(a0)               # a0 = &chain[1] again
    sub  a2, a0, s0

    la   s1, bytes
    mv   a3, s1
    lb   a3, 3(a3)               # rd == base, sign-extended byte
    add  a4, a3, a3
    mv   a3, s1
    lbu  a3, 3(a3)
    add  a4, a4, a3
    mv   a3, s1
    lh   a3, 2(a3)
    add  a4, a4, a3
    mv   a3, s1
    lhu  a3, 2(a3)
    add  a4, a4, a3

    # Compressed: c.lw rd' == rs1' (x8-x15), chased; c.lwsp into sp.
    mv   s1, s0                  # s1 = x9
.option rvc
    c.lw s1, 0(s1)               # s1 = &chain[1]
    c.lw s1, 0(s1)               # s1 = &chain[2]
    c.lw s1, 4(s1)               # s1 = &chain[0]
.option norvc
    add  a5, s1, s1
    mv   sp, s0
.option rvc
    c.lwsp sp, 0(sp)             # sp = &chain[1]
    c.lwsp sp, 0(sp)             # sp = &chain[2]
.option norvc
    sub  a6, sp, s0

    # Store data == base, then load it back through itself.
    la   t0, slot
    sw   t0, 0(t0)               # stores its own address
    lw   t0, 0(t0)               # rd == base again
    lw   t1, 0(t0)
    sub  t2, t1, t0
.option rvc
    mv   s1, t0                  # becomes c.mv
    c.sw s1, 4(s1)               # rs2' == rs1'
    c.lw s1, 4(s1)
.option norvc
    sub  t3, s1, t0

    # Load feeding both operands of a branch and a store at once.
    lw   t4, 0(s0)
    beq  t4, t4, 1f
    addi t5, x0, 1
1:  lw   t4, 0(s0)
    sw   t4, 8(t0)
    lw   t5, 8(t0)

    li   t6, 1
    la   a7, tohost
    sw   t6, 0(a7)
2:  j 2b

.section .data
.balign 16
chain: .word chain + 4, chain + 8, chain + 12, chain
bytes: .word 0x8180ff7f
slot:  .word 0, 0, 0, 0
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
