# MRET to a target that is not the next instruction, under fetch wait
# states: the redirect must wait until the outstanding fetch completes.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, far
  csrw mepc, t0
  li   t1, 0x1800
  csrs mstatus, t1
  mret
  li   a0, 0xbad
  li   a0, 0xbad
  li   a0, 0xbad
far:
  li   a1, 0x600d
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
