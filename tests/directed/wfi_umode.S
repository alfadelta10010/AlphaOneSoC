# WFI executed in U-mode (CPU ref 8.5; Priv 3.1.6.6, 3.3.3, 3.7.1).
#   A. TW=0, mie=0: WFI is a NOP (nothing enabled to wake it), so the next
#      instruction, an ECALL, traps with cause 8 and mepc = the ECALL.
#   B. TW=0, MTIE set, timer armed 5000 clocks ahead: WFI is still legal. It
#      is either a NOP (FyraCore: the ECALL after it traps, cause 8, mepc =
#      after_b + 4, s8 = 1) or it waits for the timer (cause 0x80000007,
#      mepc = after_b, s8 = 0; U-mode never masks M-mode interrupts). Both
#      pass; what must not happen is an illegal-instruction trap.
#   C. TW=1: WFI is an illegal instruction (cause 2), mepc = the WFI.
# Not Spike-comparable: Spike 5a760667 with --priv=mu retires a U-mode WFI
# with TW=0 and then sleeps forever when mie=0 (it does not trap it), where
# FyraCore treats it as a NOP; both are legal. The timer counts clocks, so
# phase B is DUT-only as well. The test grants U-mode a NAPOT PMP entry over
# everything first (Priv 3.7.1: with no matching entry a U-mode fetch faults).
# The task's first draft assumed Spike traps the U-mode WFI and that the core
# waits; the core in fact treats it as a NOP (WFI waits in M-mode only), so
# phase B accepts both legal outcomes. FC45 (U-mode WFI always illegal) fails
# phases A and B.
# Results: x9 = traps taken (3); x18/x19 = A's mcause and mepc - ECALL;
# x20/x21 = B's mcause and mepc - after_b; x22/x23 = C's mcause and mepc - WFI;
# x24 = number of times the instruction after B's WFI ran (1 as a NOP, 0 if it waited).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s1, 0
  li   s8, 0
  li   t0, -1
  csrw pmpaddr0, t0
  li   t0, 0x1f
  csrw pmpcfg0, t0
  li   t0, 0x201800            # TW and MPP
  csrc mstatus, t0
  li   s0, 0x02000000
  li   t1, 0x4000
  add  s10, s0, t1             # &mtimecmp
  li   t1, 0xBFF8
  add  s9, s0, t1              # &mtime
  # phase A
  csrw mie, zero
  la   s11, cont_a
  la   t0, ua
  csrw mepc, t0
  mret
ua:
  wfi
ecall_a:
  ecall
cont_a:
  mv   s2, a6
  la   t0, ecall_a
  sub  s3, a7, t0
  # phase B
  li   t3, -1
  sw   t3, 4(s10)               # hi first, so no spurious match
  lw   t2, 0(s9)
  li   t1, 5000
  add  t2, t2, t1
  sw   t2, 0(s10)
  sw   zero, 4(s10)
  li   t0, 0x80
  csrw mie, t0
  la   s11, cont_b
  la   t0, ub
  csrw mepc, t0
  mret
ub:
  wfi
after_b:
  addi s8, s8, 1
  ecall
cont_b:
  li   t3, -1
  sw   t3, 4(s10)               # disarm
  csrw mie, zero
  mv   s4, a6
  la   t0, after_b
  sub  s5, a7, t0
  # phase C
  li   t0, 0x200000
  csrs mstatus, t0
  la   s11, cont_c
  la   t0, uc
  csrw mepc, t0
  mret
uc:
  wfi
  ecall
cont_c:
  mv   s6, a6
  la   t0, uc
  sub  s7, a7, t0
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .balign 4
handler:
  addi s1, s1, 1
  csrr a6, mcause
  csrr a7, mepc
  li   t0, 0x1800
  csrs mstatus, t0
  csrw mepc, s11
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
