# Which CSR writes does Spike log, and under which names?
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   t0, 0x02004000        # mtimecmp = -1, so MTIP reads 0 on both models
  li   t1, -1
  sw   t1, 0(t0)
  sw   t1, 4(t0)
  li   t1, 0x55
  csrw 0x3a1, t1        # pmpcfg1 (unimplemented at 4 regions)
  csrw 0x3b4, t1        # pmpaddr4
  csrw 0x310, t1        # mstatush
  csrw 0x30a, t1        # menvcfg
  csrw 0x31a, t1        # menvcfgh
  csrw 0xb03, t1        # mhpmcounter3
  csrw 0xb83, t1        # mhpmcounter3h
  csrw 0x323, t1        # mhpmevent3
  csrw 0x747, t1        # mseccfg
  csrw 0x344, t1        # mip
  csrr a0, 0x310
  csrr a1, 0x30a
  csrr a2, 0xb03
  csrr a3, 0x323
  csrr a4, 0x344
  csrr a5, 0xc03        # hpmcounter3 (user)
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .align 2
handler:
  csrr t2, mcause
  csrr t3, mepc
  addi t3, t3, 4
  csrw mepc, t3
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
