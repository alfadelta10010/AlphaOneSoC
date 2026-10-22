# An interrupt that becomes pending and enabled while the instructions ahead
# of it are a MUL (no interrupt is injected while an M instruction is in EX)
# and then an ECALL: at the ECALL both the interrupt and the exception are
# there to be taken.
#
# Expect mode, not Spike: both orders are legal and the two models choose
# differently. Spike takes the interrupt at the first instruction boundary
# after msip is written (mepc = the MUL); FyraCore lets the ECALL trap first
# (CPU reference 8.4) and takes the interrupt at the MRET's return, after the
# ECALL. The current Privileged spec orders interrupts among themselves
# (3.1.9) and no longer ranks synchronous exceptions against them; interrupt
# recognition may take any number of instructions. What must hold either
# way: each handler runs exactly once (x10 = interrupts taken = 1, x11 =
# ECALLs taken = 1), the interrupt's mepc is an instruction boundary of this
# sequence (x12 = its offset from `seq`: 0 the MUL, 4 the ECALL, 8 after it),
# and the program then runs on normally (x13 = 0x55).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   a0, 0
  li   a1, 0
  li   a2, -1
  li   a3, 0
  li   s1, 0x02000000         # CLINT msip
  sw   zero, 0(s1)
  li   t0, 8
  csrw mie, t0                # MSIE
  csrsi mstatus, 8            # MIE
  li   t1, 1
  li   t2, 3
  sw   t1, 0(s1)              # msip = 1: pending and enabled from here
seq:
  mul  t3, t2, t2
  ecall
  li   a3, 0x55
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .balign 4
handler:
  csrr t0, mcause
  bltz t0, irq
  addi a1, a1, 1              # the ECALL
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret
irq:
  addi a0, a0, 1
  sw   zero, 0(s1)            # msip = 0
  csrr t0, mepc
  la   t1, seq
  sub  a2, t0, t1
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
