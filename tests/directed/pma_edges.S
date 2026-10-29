# The last byte of every mapped window is mapped, and the first byte past
# it is not (CPU ref 4; the testbench's windows match Spike's -m map: PSRAM
# 0x80000000-0x80FFFFFF, flash 0x20000000-0x20FFFFFF). Loads at the last
# byte, halfword and word of PSRAM and flash; stores at PSRAM's (flash is
# read-only here and RAM on Spike, a known legal divergence, so no store
# goes there); loads one byte past each end and just below each start,
# which must fault (cause 5, mtval the address). The CLINT is only touched
# where both models agree: its last register, and past and below the
# window. The CLINT window is 0x0200_0000-0x0200_BFFF on both models
# (Spike 5a760667's map; the testbench's IO0_TOP): its last byte reads, and
# a load and a store at 0x0200_C000 fault (cause 5, 7). The handler copies mcause and mtval
# into registers and skips the access.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   t1, 0x5a
  li   t2, 0xa55a
  li   s0, 0x80ffffff
  sb   t1, 0(s0)
  lb   a0, 0(s0)
  lbu  a1, 0(s0)
  li   s0, 0x80fffffe
  sh   t2, 0(s0)
  lh   a2, 0(s0)
  li   s0, 0x80fffffc
  lw   a3, 0(s0)
  sw   t2, 0(s0)
  lw   a4, 0(s0)
  li   s0, 0x81000000           # past PSRAM
  lb   a5, 0(s0)
  sb   t1, 0(s0)
  li   s0, 0x7fffffff           # below PSRAM
  lb   a5, 0(s0)
  li   s0, 0x20ffffff           # last byte of flash
  lbu  a6, 0(s0)
  li   s0, 0x20fffffc
  lw   a7, 0(s0)
  li   s0, 0x21000000           # past flash
  lb   a5, 0(s0)
  li   s0, 0x1fffffff           # below flash
  lb   a5, 0(s0)
  li   s0, 0x0200bffc           # mtime_hi, the CLINT's last register
  lw   s3, 0(s0)
  lbu  s6, 3(s0)                # the window's last byte, 0x0200bfff
  li   s0, 0x0200c000           # the first byte past the window
  lw   s4, 0(s0)                # cause 5 on both models
  sw   t2, 0(s0)                # cause 7 on both models
  li   s0, 0x01fffffc           # below it
  lw   s5, 0(s0)
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .balign 4
handler:
  csrr t3, mcause
  csrr t4, mtval
  csrr t5, mepc
  addi t5, t5, 4
  csrw mepc, t5
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
