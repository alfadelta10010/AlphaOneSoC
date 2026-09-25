# Same-hart writes to the reserved word, of any width, clear the reservation:
# word store, byte store into byte 1, AMO. Spike keeps the reservation on all
# three (both are legal), so this checks the core's policy, not Spike.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   s0, 0x80800000
  sw   x0, 0(s0)
  lr.w a0, (s0)
  li   t1, 0x55
  sw   t1, 0(s0)          # word store to the reserved word
  li   t2, 0x77
  sc.w a1, t2, (s0)       # DUT policy: fails
  lr.w a0, (s0)
  sb   t1, 1(s0)          # byte store into the same reserved word
  sc.w a2, t2, (s0)       # DUT policy says "overlapping write clears" -> should fail too
  lr.w a0, (s0)
  amoadd.w x0, t1, (s0)
  sc.w a3, t2, (s0)
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
