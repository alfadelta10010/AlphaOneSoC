# MRET executed with MIE=1 and an interrupt pending: the interrupt is taken
# instead of the MRET (mepc = the MRET), and the MRET must not also commit.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x02000000        # msip
  la   t0, target
  csrw mepc, t0
  li   t0, 0x1800
  csrc mstatus, t0           # MPP=U
  li   t0, 0x80
  csrs mstatus, t0           # MPIE=1
  li   t0, 8
  csrs mie, t0               # MSIE
  li   t0, 1
  sw   t0, 0(s0)             # msip=1 (pending)
  nop
  nop
  csrsi mstatus, 8           # MIE=1: spike takes the interrupt right after this
  mret
target:
  nop
  j target
  .align 2
handler:
  csrr a4, mepc
  csrr a5, mstatus
  csrr a6, mcause
  sw   x0, 0(s0)
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
