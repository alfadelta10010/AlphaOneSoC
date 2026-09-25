# Jumping to an address with nothing mapped must fault with cause 1 and
# mtval = the target, without the core ever requesting the fetch -- an
# unmapped address would never answer. Run under fetch wait states, where
# a request that waited for a ready would show up as a hang.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0
  li   t1, 0x40000000        # nothing mapped here
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
