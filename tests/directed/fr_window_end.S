# Fetch word reuse (WO-27): the last two halfwords of the executable window
# (0x80FFFFFC, 0x80FFFFFE) run as a compressed pair, then again the last one
# alone. The fetch of 0x80FFFFFE brings in a word whose upper half is outside
# the window: it must be masked to 0 and the next instruction (0x81000000)
# must fault with cause 1 and mtval = 0x81000000, not run what the memory
# returned there. The handler goes on to the second round.
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
  la   t0, handler
  csrw mtvec, t0
  li   s10, 0
  li   t1, 0x80FFFFFC
  jr   t1
back:
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  ALIGN4
handler:
  csrr s2, mcause
  csrr s3, mepc
  csrr s4, mtval
  addi s10, s10, 1
  li   t0, 2
  beq  s10, t0, back2
  li   t1, 0x80FFFFFE
  csrw mepc, t1
  mret
back2:
  la   t0, back
  csrw mepc, t0
  mret
  .section .window_end,"ax",@progbits
  .option rvc
  c.li a1, 6
  c.li a2, 7
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
