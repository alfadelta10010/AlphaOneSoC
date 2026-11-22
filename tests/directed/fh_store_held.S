# WO-76: no held word under a store. A store S rewrites the word of
# instruction Y (no FENCE.I), a long M op X follows S, then Y runs. With
# +DMEM_WAIT=20 +IMEM_WAIT=0 Y's fetch completes while S is still in WB: the
# core must not keep that word (it was read before S wrote), so the fetch is
# requested again and Y executes as the new instruction, as in Spike. The
# fetch hold's "no data access in WB" term is what this tests.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   s0, 8                  # iterations
  li   a2, 0
  li   a4, 0
  li   a0, 3
  li   a1, 5
  la   t0, Y
loop:
  slli t1, s0, 20             # addi a2, a2, s0 : imm = s0
  li   t2, 0x00060613
  or   t1, t1, t2
  sw   t1, 0(t0)              # S
  mul  a3, a0, a1             # X
  .align 2
Y:
  addi a2, a2, 1              # rewritten by S
  add  a4, a4, a2
  addi s0, s0, -1
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
