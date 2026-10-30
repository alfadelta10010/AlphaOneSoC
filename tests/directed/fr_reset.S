# Fetch word reuse (WO-27): a reset while the core holds a kept halfword
# (if_kv = 1). core_reset resets inside a workload that has cleared misa.C, so
# its resets never meet a compressed pair. Here the loop is all compressed
# instructions, two per word: after every fetch the second one is kept, and
# resets at strides 1 and 7 land on every phase of it, with if_kv set in half
# of them. A core whose if_kv survived the reset would issue the old stream's
# halfword in place of the first instruction at the reset vector (tb_rivercore's
# if_kv shadow check fails on the first cycle after the reset).
#
# Expect mode, DUT only: Spike has no reset. Boots are counted in memory
# (scratch word SCR, zero at first). Result: x11 = boots (160).
  .section .text.init
  .globl rvtest_entry_point
  .equ SCR, 0x80F00000
rvtest_entry_point:
  .option norvc
  li   s0, SCR
  lw   s1, 0(s0)
  addi t0, s1, 1
  sw   t0, 0(s0)
  li   t0, 160
  beq  s1, t0, finish
  li   a0, 0
  li   a1, 0
  .balign 4
  .option rvc
loop:
  c.addi a0, 1
  c.addi a1, 2
  c.addi a0, 3
  c.addi a1, 4
  c.addi a0, 5
  c.addi a1, 6
  c.nop
  c.j  loop
  .option norvc
finish:
  mv   a1, s1
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
