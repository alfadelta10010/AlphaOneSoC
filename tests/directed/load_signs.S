# LB/LH sign-extend from the loaded byte's / halfword's own top bit, LBU/LHU
# zero-extend (Unpriv 2.6). Every test word has exactly one byte whose top
# bit differs from the other three, so a sign taken from the wrong bit (bit
# 23 instead of 31 for byte 3, bit 15 instead of 31 for the upper half, ...)
# gives a different result on at least one of them. mem_align's words had the
# same top bit in every byte and could not tell (FC25). Each load goes to a
# register, so the trace shows it and Spike checks it.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   s0, 0x80800000
  li   t1, 0x807f7f7f
  sw   t1, 0(s0)
  li   t1, 0x7f807f7f
  sw   t1, 4(s0)
  li   t1, 0x7f7f807f
  sw   t1, 8(s0)
  li   t1, 0x7f7f7f80
  sw   t1, 12(s0)
  li   t1, 0x7f808080
  sw   t1, 16(s0)
  li   t1, 0x807f8080
  sw   t1, 20(s0)
  li   t1, 0x80807f80
  sw   t1, 24(s0)
  li   t1, 0x8080807f
  sw   t1, 28(s0)
.irp w, 0, 4, 8, 12, 16, 20, 24, 28
  lb   a0, \w+0(s0)
  lbu  a1, \w+0(s0)
  lb   a2, \w+1(s0)
  lbu  a3, \w+1(s0)
  lb   a4, \w+2(s0)
  lbu  a5, \w+2(s0)
  lb   a6, \w+3(s0)
  lbu  a7, \w+3(s0)
  lh   t2, \w+0(s0)
  lhu  t3, \w+0(s0)
  lh   t4, \w+2(s0)
  lhu  t5, \w+2(s0)
.endr
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
