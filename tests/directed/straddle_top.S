# A 32-bit instruction at 0x81FFFFFE straddles the end of the memory window:
# cause 1, mepc at the instruction, mtval at its upper half.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   a0, 0x5a5a
  li   t1, 0x81FFFFFE
  jalr x0, 0(t1)
  .align 2
handler:
  csrr s0, mcause
  csrr s1, mepc
  csrr s2, mtval
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .section .straddle,"ax",@progbits
  .half 0x0513            # low half of addi a0,x0,... (32-bit encoding, bits[1:0]=11)
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
