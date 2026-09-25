  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   a0, 0x80100000
  li   t1, 0x11112222
  sw   t1, 0(a0)
  # amoadd
  li   t2, 0x00010001
  amoadd.w a1, t2, (a0)        # a1 = old = 0x11112222, mem = 0x11122223
  lw   a2, 0(a0)
  # amoswap
  li   t3, 0xDEADBEEF
  amoswap.w a3, t3, (a0)
  lw   a4, 0(a0)
  # amomax / amominu
  li   t4, 0x7fffffff
  amomax.w a5, t4, (a0)
  lw   a6, 0(a0)
  # lr/sc success
  lr.w  a7, (a0)
  addi  s2, a7, 1
  sc.w  s3, s2, (a0)           # s3 = 0 success
  lw    s4, 0(a0)
  # sc without lr -> fail
  sc.w  s5, s2, (a0)           # s5 = 1
  # (lr; store to the same word; sc is a spec-legal divergence -- the core
  # fails the SC, Spike does not -- and is checked by lr_sb_sc instead)
  li    s7, 0
  lw    s8, 0(a0)
  # sub-word stores under wait states
  li    a1, 0x80100010
  li    t5, 0xAABBCCDD
  sw    t5, 0(a1)
  li    t6, 0x55
  sb    t6, 1(a1)
  li    t6, 0x9999
  sh    t6, 2(a1)
  lw    s9, 0(a1)
  lbu   s10, 1(a1)
  lhu   s11, 2(a1)
  # dump
  li    a2, 0x80100020
  sw    a7, 0(a2)
  sw    s3, 4(a2)
  sw    s4, 8(a2)
  sw    s5, 12(a2)
  sw    s7, 16(a2)
  sw    s8, 20(a2)
  sw    s9, 24(a2)
  sw    s10, 28(a2)
  sw    s11, 32(a2)
  j done
handler:
  csrr s11, mcause
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret
done:
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
