  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  csrr s0, pmpcfg0
  csrr s1, pmpaddr0
  csrr s2, pmpaddr1
  csrr s3, mstatus
  csrr s4, misa
  csrr s5, mtvec
  csrr s6, mie
  csrr s7, mip
  csrr s8, mcause
  li   t0, 0x80100000
  sw   s0,0(t0)
  sw   s1,4(t0)
  sw   s2,8(t0)
  sw   s3,12(t0)
  sw   s4,16(t0)
  sw   s5,20(t0)
  sw   s6,24(t0)
  sw   s7,28(t0)
  sw   s8,32(t0)
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
