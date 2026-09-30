# WFI woken by the machine timer, at a period a QSPI-speed pipeline can keep
# up with (3000 clocks ahead). From the design review of 2026-09-26, V6.
#
#   1. MIE=1, MTIE=1, WFI: the interrupt is taken while the hart waits, with
#      mepc = the instruction after the WFI (privileged spec 3.3.3: the trap
#      is taken on the following instruction).
#   2. MIE=0, MTIE=1, WFI: pending-and-enabled in mie wakes it without a trap
#      (MIE only gates the trap), and MTIP then reads pending in mip.
#   3. MTIP still pending, then MIE=1 and WFI: the interrupt becomes takeable
#      as the WFI reaches EX. The core completes the WFI and takes it on the
#      next instruction, mepc = WFI+4, as in 1; a WFI returned to with mepc
#      pointing at it would sleep for good, the timer being disarmed. (Spike
#      takes it before the WFI, mepc = WFI: also legal.)
#
# DUT-only: the timer counts clocks, Spike counts instructions. Results:
#   x18 (s2) = interrupts taken, 2
#   x9  (s1) = mepc - after1 in 1, 0
#   x20 (s4) = mcause, 0x80000007
#   x21 (s5) = 0x77 once the second WFI has fallen through
#   x22 (s6) = mip after it, 0x80 (MTIP)
#   x10 (a0) = mepc - after3 in 3, 0
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x02000000
  li   t1, 0x4000
  add  s7, s0, t1             # &mtimecmp
  li   t1, 0xBFF8
  add  s8, s0, t1             # &mtime
  li   s2, 0                  # interrupts taken
  li   s3, 0                  # mepc seen
  li   s4, 0                  # mcause seen
  li   t3, -1
  sw   t3, 4(s7)              # hi first, so no spurious match on the way
  lw   t2, 0(s8)
  li   t1, 3000
  add  t2, t2, t1
  sw   t2, 0(s7)
  sw   zero, 4(s7)
  li   t1, 0x80
  csrs mie, t1
  csrsi mstatus, 8
wfi1:
  wfi
after1:
  csrci mstatus, 8
  la   t0, after1
  sub  s1, s3, t0             # 0 if mepc was the instruction after the WFI
  # MIE=0: arm the timer again; the WFI must wake without a trap.
  li   t3, -1
  sw   t3, 4(s7)
  lw   t2, 0(s8)
  li   t1, 3000
  add  t2, t2, t1
  sw   t2, 0(s7)
  sw   zero, 4(s7)
wfi2:
  wfi
  li   s5, 0x77
  csrr s6, mip
  # MTIP is still pending: enabling MIE right before a WFI.
  csrsi mstatus, 8
wfi3:
  wfi
after3:
  csrci mstatus, 8
  la   t0, after3
  sub  a0, s3, t0
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
2: j 2b

  .align 2
handler:
  addi s2, s2, 1
  csrr s3, mepc
  csrr s4, mcause
  li   t3, -1
  sw   t3, 4(s7)              # disarm
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
