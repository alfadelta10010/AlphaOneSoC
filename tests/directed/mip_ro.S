# mip has no writable bits (M+U, no Sscofpmf): writes are ignored, reads
# return only the live MSIP/MTIP/MEIP. mtimecmp is set to -1 first so MTIP
# is 0 on both models (their mtimecmp reset values differ).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   s0, 0x02000000
  li   t0, -1
  li   s1, 0x02004000
  sw   t0, 0(s1)            # mtimecmp lo
  sw   t0, 4(s1)            # mtimecmp hi
  li   t1, -1
  csrw mip, t1
  csrr a0, mip              # forwarded read: 0
  nop
  csrr a1, mip              # register read: 0
  li   t0, 1
  sw   t0, 0(s0)            # msip = 1
  nop
  nop
  csrw mip, zero
  csrr a2, mip              # forwarded read: live MSIP = 0x8
  csrs mip, t1
  nop
  csrr a3, mip              # 0x8
  sw   zero, 0(s0)
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
