  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   a0, 100
  li   a1, 7
  div  a2, a0, a1
  rem  a3, a0, a1
  mulh a4, a0, a1
  li   t0, 0x80100000
  sw   a2, 0(t0)
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
