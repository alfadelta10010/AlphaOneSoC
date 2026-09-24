# A load whose address comes from an AMO's read phase: EX sees the AMO's
# data before dmem_ready. With garbage not-ready data the trap redirect used
# to fire on a trap that was never taken (C3).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x81000000
  li   t1, 0x81000100
  sw   t1, 0(s0)
  amoor.w a0, zero, (s0)   # a0 = 0x81000100 via the AMO read phase
  lw   a1, 0(a0)
  addi a2, a1, 1
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .align 2
handler:
  li   a5, 0xbad
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
