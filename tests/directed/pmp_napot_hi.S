# pmpaddr[31:30] (PA[33:32]) are not implemented: 0x9fffffff reads back
# 0x1fffffff, the all-memory NAPOT region, so the U-mode fetch is allowed
# (Spike keeps the bits and faults: an `expect` test, see MANIFEST).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   t1, 0x9fffffff
  csrw pmpaddr0, t1
  li   t1, 0x1f
  csrw pmpcfg0, t1
  csrr a3, pmpaddr0
  la   t0, umode
  csrw mepc, t0
  li   t0, 0x1800
  csrc mstatus, t0
  nop
  mret
umode:
  li   a2, 0x111
  ecall
  .align 2
handler:
  csrr a4, mcause
  csrr a5, mtval
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
