# Fetch word reuse (WO-27): self-modifying code without FENCE.I. C1 is a
# c.sw whose word overwrites C2 (and the halfword behind it). C2 was fetched
# together with C1 and is kept, so the OLD C2 runs. That is legal: Zifencei
# only promises that a fetch sees a store after a FENCE.I. This test pins
# the window (a2 = 1, the old c.li a2,1). The second case puts a FENCE.I
# between the store and the patched instruction: the new one must run
# (a3 = 5).
  .section .text.init
  .macro ALIGN4                # in rvc mode, so the linker keeps the alignment
    .option push
    .option rvc
    .balign 4
    .option pop
  .endm
  .globl rvtest_entry_point
rvtest_entry_point:
  .option norvc
  la   s0, tgt1
  la   s1, tgt2
  li   a0, 0x00014615        # c.li a2,5 | c.nop behind it
  li   a1, 0x00014695        # c.li a3,5 | c.nop behind it
  ALIGN4
  .option rvc
  c.nop
  c.sw a0, 0(s0)             # at 2 mod 4
  .option norvc
  .option rvc
tgt1:
  c.li a2, 1                 # patched to c.li a2,5 -- but already in hand
  c.nop
  c.nop
  .option norvc
  ALIGN4
  .option rvc
  c.nop
  c.sw a1, 0(s1)
  .option norvc
  fence.i
tgt2:
  .option rvc
  c.li a3, 1                 # patched to c.li a3,5: runs as patched
  c.nop
  .option norvc
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
