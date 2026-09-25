# Whole trap-cause chain in one program. Each trap appends its mcause as a
# nibble to s0; the handler skips the faulting instruction (all 4 bytes, hence
# .option norvc). Expected sequence 11,3,5,7,4,6,2 -> 0x0B357462.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   t6, handler
    csrw mtvec, t6
    li   s0, 0
    ecall                      # 11
    ebreak                     # 3
    li   a0, 0x40000000        # unmapped in both models
    lw   t0, 0(a0)             # 5
    sw   t0, 0(a0)             # 7
    li   a1, 0x80800001        # mapped but misaligned
    lw   t0, 0(a1)             # 4
    sw   t0, 0(a1)             # 6
    .word 0xffffffff           # 2
    mv   a2, s0
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
1:  j 1b
.balign 4
handler:
    csrr t1, mcause
    slli s0, s0, 4
    or   s0, s0, t1
    csrr t2, mepc
    addi t2, t2, 4
    csrw mepc, t2
    mret
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
