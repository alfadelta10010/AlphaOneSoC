  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   t1, 4
  .align 2
  csrc misa, t1            # PC is 4-byte aligned -> clear of C is allowed
  nop
  nop
  csrr s4, misa            # confirm C cleared
  li   t2, 0x80000102
  csrw mepc, t2            # bit1 set; IALIGN=32 now
  csrr s0, mepc            # forwarded read
  nop
  csrr s1, mepc            # register read
  li   t1, 4
  csrs misa, t1            # set C again
  nop
  nop
  csrr s2, mepc            # is bit1 retained (spec) or destroyed (spike)?
  li   t0, 0x80100000
  sw   s4, 0(t0)
  sw   s0, 4(t0)
  sw   s1, 8(t0)
  sw   s2, 12(t0)
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
handler:
  csrr s11, mcause
  j 1b
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
