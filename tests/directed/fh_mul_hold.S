# WO-76: a fetch that completes while an M op or a serial shift stalls the
# pipeline is kept (fetch hold register) and not requested again. Each M op
# is followed by a 32-bit instruction and a compressed pair, so the held
# word is used as a whole 32-bit instruction, as a compressed instruction
# with a kept halfword behind it, and as a 32-bit instruction that starts at
# a halfword. Every result feeds a register that Spike's trace compares.
  .option rvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   s0, 12                 # iterations
  li   a0, 0x12345678
  li   a1, 7
  li   a2, 0
  li   a3, 0
loop:
  mul  a2, a0, a1             # 34-cycle multiply, fetch of the next word completes under it
  addi a3, a3, 5              # 32-bit, aligned
  c.addi a3, 3                # compressed pair behind it
  c.addi a3, -1
  div  a4, a0, a1
  xori a3, a3, 0x55
  rem  a5, a0, a1
  c.addi a3, 1                # a compressed instruction first, then a 32-bit one at pc + 2
  slli a6, a0, 31             # serial shift
  c.mv a7, a6
  addi a3, a3, 9
  mulhu a2, a2, a1
  c.add a3, a2
  srli a6, a6, 30
  c.nop
  add  a3, a3, a6
  add  a3, a3, a4
  c.add a3, a5
  c.add a0, a3
  c.addi s0, -1
  bnez s0, loop
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
