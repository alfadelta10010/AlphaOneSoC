# Jumping into the CLINT (an IO window, data only) must fault with cause 1
# and mtval = the target, without the core requesting the fetch: a read of
# a device can have side effects. Spike instead reads the device and raises
# cause 2 on the bits it gets, so this is checked DUT-only.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0
  li   t1, 0x02000000        # msip, in the CLINT window
  jalr x0, 0(t1)
back2:
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .balign 4
handler:
  csrr a0, mcause
  csrr a1, mtval
  la   t3, back2
  csrw mepc, t3
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
