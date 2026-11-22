# WO-76: performance floor of the fetch hold, cache on (SoC only, +CACHE_EN).
# mcycle of 100 iterations of an ALU loop and of a MUL loop, all 32-bit, in
# the cache after the first pass (the first pass fills the lines). The bounds are the measured count with the
# hold plus 2 % (measured 1862 and 5270 clocks, sandbox 2026-11-22; without the hold 2259 and 5666, above them), which is what makes the
# test kill a core that discards the completed fetch. x10 = 1 when both loops
# meet their bound; x11, x12 = the two counts.
  .option norvc
  .equ BOUND_ALU, 1900
  .equ BOUND_MUL, 5380
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   s0, 100
  li   a0, 3
  li   a3, 5
  .align 4
  csrr s2, mcycle
alu:
  addi t0, t0, 1
  add  t1, t1, t0
  xor  t2, t2, t1
  addi s0, s0, -1
  bnez s0, alu
  csrr s3, mcycle
  sub  a1, s3, s2             # x11 = ALU loop clocks
  li   s0, 100
  csrr s2, mcycle
mu:
  addi t0, t0, 1
  mul  t1, a0, a3
  xor  t2, t2, t1
  addi s0, s0, -1
  bnez s0, mu
  csrr s3, mcycle
  sub  a2, s3, s2             # x12 = MUL loop clocks
  li   t3, BOUND_ALU
  li   t4, BOUND_MUL
  li   a0, 0
  bgtu a1, t3, done
  bgtu a2, t4, done
  li   a0, 1
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
