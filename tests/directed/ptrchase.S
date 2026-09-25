# Pointer chase: the second load's address comes from the first load, so it
# sits in EX (load-use stall) while the first waits for dmem_ready.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x81000000
  li   t1, 0x81000100
  sw   t1, 0(s0)
  li   t2, 0x1234
  sw   t2, 0x100(s0)
  lw   a0, 0(s0)          # a0 = 0x81000100
  lw   a1, 0(a0)          # a1 = 0x1234
  addi a2, a1, 1
  addi a3, a2, 1
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .align 2
handler:
  li   a5, 0xbad
  csrr a6, mcause
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
2: j 2b
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
