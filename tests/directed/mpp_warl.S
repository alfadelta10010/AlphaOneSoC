# mstatus.MPP WARL: reset value, and what a write of each MPP value leaves.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  csrr a0, mstatus          # reset value
  li   t1, 0x1800
  csrs mstatus, t1          # MPP=11
  csrr a1, mstatus
  li   t2, 0x1000
  csrw mstatus, t2          # MPP=10 written over MPP=11
  csrr a2, mstatus
  csrs mstatus, t1          # MPP=11
  li   t2, 0x0800
  csrw mstatus, t2          # MPP=01 written over MPP=11
  csrr a3, mstatus
  csrc mstatus, t1          # MPP=00
  csrr a4, mstatus
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
