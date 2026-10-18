# A read of a user-level counter alias right after a write to its M-level
# name must see the write (the aliases read the same register).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   t1, 0x1000
  csrw minstret, t1
  csrr a0, instret          # adjacent: must be forwarded
  li   t1, 0x7
  csrw minstreth, t1
  csrr a1, instreth
  # mcycle counts clocks (Spike: instructions), so it is stopped for its
  # two cases (mcountinhibit.CY): the alias must show the value written,
  # whatever the read's distance from the write.
  li   t0, 1
  csrw mcountinhibit, t0
  li   t1, 0x2000
  csrw mcycle, t1
  csrr a2, cycle
  li   t1, 0x9
  csrw mcycleh, t1
  csrr a3, cycleh
  csrw mcountinhibit, x0
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
