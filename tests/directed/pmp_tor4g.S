# TOR with the largest pmpaddr this core has (PA[33:32] are not implemented,
# and the 4 KiB grain clears bits [9:0]): the top reads 0x3ffffc00, PA
# 0xfffff000, so the region covers all of memory below the last page and
# U-mode may execute.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  csrw pmpcfg0, zero          # Spike resets pmpcfg0 to NAPOT RWX, the core to OFF: start both from OFF (a pmpaddr write is logged as read back)
  la   t0, handler
  csrw mtvec, t0
  li   t1, 0x3fffffff
  csrw pmpaddr0, t1
  li   t1, 0x0f
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
