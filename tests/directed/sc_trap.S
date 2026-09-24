# sc.w immediately followed by a trapping instruction. The trap clear is
# ungated (ex_trap), so under a data wait state it clears the reservation
# while the SC is still waiting for dmem_ready: SC withdraws its store.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x81000000
  li   t1, 0x11
  sw   t1, 0(s0)
  lr.w a0, (s0)
  li   t2, 0x22
  sc.w a1, t2, (s0)
  ecall
  .align 2
back:
  lw   a2, 0(s0)
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .align 2
handler:
  la   t0, back
  csrw mepc, t0
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
