# WFI executed in U-mode (CPU ref 8.5; Priv 3.1.6.6, 3.3.3, 3.7.1).
#   A. TW=0, mie=0: WFI is a NOP (nothing enabled to wake it), so the next
#      instruction, an ECALL, traps with cause 8 and mepc = the ECALL.
#   B. TW=0, MTIE set, timer armed 5000 clocks ahead. The WFI is a NOP (CPU
#      ref 8.5, as of 1a845f5; SA-006 closed 2026-10-23 as a doc fix): the
#      addi s8 after it runs (s8 = 1) and the ECALL after that traps with
#      cause 8, mepc = after_b + 4. A core whose U-mode WFI waits takes the
#      timer interrupt instead (cause 0x80000007, mepc = after_b, s8 = 0):
#      that is mutant FC86. M-mode interrupts are always enabled in U-mode
#      (Priv 3.1.9), so MIE does not matter there. The handler clears MPIE so
#      every continuation runs with MIE = 0 (a still pending timer cannot
#      re-enter the handler before cont_b disarms it).
#   C. TW=1: WFI is an illegal instruction (cause 2), mepc = the WFI.
# Not Spike-comparable: Spike 5a760667 with --priv=mu retires a U-mode WFI
# with TW=0 and then sleeps forever when mie=0 (it does not trap it), so this
# is an expect-mode test. The timer counts clocks, so phase B is DUT-only as
# well. The test grants U-mode a NAPOT PMP entry over everything first (Priv
# 3.7.1: with no matching entry a U-mode fetch faults). FC45 (U-mode WFI
# always illegal) fails phases A and B (x18 = 0x2, x19 = 0xfffffffc).
# Results: x9 = traps taken (3); x18/x19 = A's mcause and mepc - ECALL;
# x20/x21 = B's mcause and mepc - after_b; x22/x23 = C's mcause and mepc - WFI;
# x24 = number of times the instruction after B's WFI ran (1).
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
  li   t0, 0x80
  csrc mstatus, t0             # MPIE = 0: the continuation runs with MIE = 0
  csrw mepc, s11
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
