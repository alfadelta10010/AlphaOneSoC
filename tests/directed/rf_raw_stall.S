# Read-after-write straight across each kind of EX stall: the M unit
# (multiply, divide), the serial shifts, the CSR-write stall, a load, an SC
# and a JALR. The register file reads synchronously: the instruction behind a
# stalled one must re-present its own registers on every stalled cycle and
# take the stalled instruction's result -- by forwarding while it is in WB,
# by the write-first capture after. Each result is read by the very next
# instruction on both ports (or as the operand the stall is about), and again
# one instruction later.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   s0, buf
    li   a0, 7
    li   a1, -3

    # M unit
    mul  a2, a0, a1
    add  a3, a2, a2
    mul  a4, a2, a2              # M -> M, both operands the M result
    mulh a5, a4, a1
    divu a6, a4, a0              # M -> divide
    beq  a6, a6, 1f              # divide -> branch, both ports
    addi a6, a6, 1
1:  rem  a7, a4, a1
    sw   a7, 0(s0)               # M -> store data
    lw   t0, 0(s0)
    div  t1, a7, a7              # rs1 == rs2
    remu t2, t1, a0

    # Serial shifts (2 + shamt cycles)
    li   t3, 31
    sll  t4, a0, t3
    srl  t5, t4, t3              # shift -> shift, result as the operand
    add  t6, t4, t5
    slli s1, t6, 13
    sra  s2, s1, a0              # shift amount from a register
    bne  s2, s1, 2f              # shift -> branch
    addi s2, s2, 1
2:  srai s3, s2, 31
    sll  s4, s3, s3              # rs1 == rs2

    # CSR-write stall: the instruction behind a CSR write waits a cycle in EX
    csrrw s5, mscratch, s4       # reads s4 (just written by a shift)
    add  s6, s5, s4              # behind the CSR write: its rd and its rs1
    csrrs s7, mscratch, s6       # a CSR write reading the previous result
    csrr  s8, mscratch
    add   s9, s8, s7
    csrrw x0, mscratch, s9       # rd = x0
    csrrwi s10, mscratch, 5
    addi  s11, s10, 1
    csrrc a2, mscratch, s11
    sub   a3, a2, s11

    # Load and SC
    lw   a4, 0(s0)
    add  a5, a4, a4
    lr.w a6, (s0)
    sc.w a7, a4, (s0)            # succeeds: a7 = 0
    add  t0, a7, a6
    sc.w t1, t0, (s0)            # fails: t1 = 1
    sll  t2, t0, t1              # SC result as a shift amount

    # JALR on a register written just before, and its link register read
    la   t3, 3f
    jalr t4, 0(t3)
    nop
3:  sub  t5, t4, t3
    la   t6, 4f
.option rvc
    c.jr t6                      # c.jr on a register written just before
.option norvc
    nop
4:  la   ra, 5f
.option rvc
    c.jalr ra                    # c.jalr x1 reads x1, then writes it
.option norvc
5:  sub  a0, ra, t6

    li   a1, 1
    la   a2, tohost
    sw   a1, 0(a2)
6:  j 6b

.section .data
.balign 16
buf: .word 0x12345678, 0, 0, 0
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
