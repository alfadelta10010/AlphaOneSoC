  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s8, 0x02000000
  li   t1, 0x4000
  add  s7, s8, t1
  li   t1, 0xBFF8
  add  s6, s8, t1
  sw   x0, 4(s7)
  li   s5, PERIOD
  lw   t2, 0(s6)
  add  t2, t2, s5
  sw   t2, 0(s7)
  li   t0, 0x80
  csrs mie, t0
  li   t0, 0x8
  csrs mstatus, t0
  li   a0, 0x80100000
  sw   x0, 0(a0)
  li   s0, 0
  li   s1, ITERS
  li   s2, 0
  li   s11, 0
outer:
#if ATOMIC
inner:
  lr.w  a1, (a0)
  addi  a2, a1, 1
  sc.w  a4, a2, (a0)
  beqz  a4, ok
  addi  s2, s2, 1
  j     inner
ok:
#else
  lw    a1, 0(a0)            # plain non-atomic control: same shape, no reservation
  addi  a2, a1, 1
  sw    a2, 0(a0)
  nop
  nop
#endif
  addi s0, s0, 1
  blt  s0, s1, outer
  lw   s9, 0(a0)
  li   t0, 0x80180000
  sw   s0, 0(t0)
  sw   s2, 4(t0)
  sw   s9, 8(t0)
  sw   s11,12(t0)
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .align 2
handler:
  addi s11, s11, 1
  lw   t5, 0(s6)
  add  t5, t5, s5
  sw   t5, 0(s7)
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
