# Self-modifying code: a store patches the next instruction, FENCE.I must
# make the new bits execute -- including when the patching store is still
# waiting on the bus while FENCE.I is in EX.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  .option norvc
  la   t0, handler
  csrw mtvec, t0
  li   s1, 0x00200513        # addi a0, zero, 2
  li   s2, 0x00300593        # addi a1, zero, 3
  li   s3, 0x0005             # c.nop -> will be patched to c.li a2, 5 (0x4615)
  li   s4, 0x4615
  la   s0, patch1
  sw   s1, 0(s0)
  fence.i
patch1:
  addi a0, zero, 1           # must execute as addi a0,zero,2
  la   s0, patch2
  sw   s2, 0(s0)
  fence.i
  nop
patch2:
  addi a1, zero, 1
  la   s0, patch3
  sh   s4, 0(s0)
  fence.i
  .option rvc
patch3:
  c.nop
  c.nop
  .option norvc
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .balign 4
handler:
  j handler
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
