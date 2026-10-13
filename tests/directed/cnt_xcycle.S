# A write to either half of mcycle is done instead of that clock's increment,
# and the clock after it is not counted either (csr.v, mcycle_wr_q), so an
# mcycleh write costs the low half exactly two counts, and the instruction
# right behind it must read the low half without them. Before 97105f2/4c8ce94
# the read port kept the increment the write had discarded.
#
# mcycle counts clocks, and how many clocks an instruction takes is the
# core's business (Spike counts one per instruction), so the value read is
# not checked. The same five instructions are run twice instead, the second
# time with the second write aimed at mscratch: both runs take the same
# clocks, and the first loses two more counts than the second. So the first
# reads exactly two less, whatever the timing.
# No memory-wait plusargs: random waits would time the two runs differently.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   t1, 0x200
  csrw mcycle, t1
  li   t2, 0x9
  csrw mcycleh, t2
  csrr a3, mcycle
  li   t1, 0x200
  csrw mcycle, t1
  li   t2, 0x9
  csrw mscratch, t2
  csrr a4, mcycle
  sub  a3, a3, a4          # -2
  csrr a5, mcycleh         # 9
  csrr a6, mscratch        # 9
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
