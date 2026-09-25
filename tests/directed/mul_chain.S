# Back-to-back M-ext ops with changing operands, no branches between.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   a0, 3
  li   a1, 5
  mul  a2, a0, a1        # 15
  li   a0, 7
  li   a1, 11
  mul  a3, a0, a1        # 77
  li   a0, 100
  li   a1, 7
  div  a4, a0, a1        # 14
  rem  a5, a0, a1        # 2
  mulh a6, a0, a1        # 0
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
