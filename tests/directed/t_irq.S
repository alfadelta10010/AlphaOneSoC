  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s10, 0                # interrupt count
  li   s9, 0                 # bad-mepc count
  # arm the timer: mtimecmp = mtime + 40
  li   s8, 0x02000000
  li   t1, 0x4000
  add  s7, s8, t1            # mtimecmp
  li   t1, 0xBFF8
  add  s6, s8, t1            # mtime
  lw   t2, 0(s6)
  addi t2, t2, 40
  sw   t2, 0(s7)
  li   t3, -1
  sw   t3, 4(s7)             # mtimecmp_hi = -1? no: set hi to 0
  sw   x0, 4(s7)
  # enable MTIE + MIE
  li   t0, 0x80
  csrs mie, t0
  li   t0, 0x8
  csrs mstatus, t0
enabled:
  # workload: muldiv + memory, interrupts land wherever
  li   s0, 0
  li   s1, 400
  li   s2, 0x80100000
loop:
  mul  t0, s0, s1
  sw   t0, 0(s2)
  lw   t1, 0(s2)
  li   t3, 7
  div  t2, s1, t3
  addi s0, s0, 1
  blt  s0, s1, loop
  # report
  li   t0, 0x80180000
  sw   s10, 0(t0)
  sw   s9, 4(t0)
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b

  .align 2
handler:
  csrr t4, mcause
  addi s10, s10, 1
  # rearm timer
  lw   t5, 0(s6)
  addi t5, t5, 40
  sw   t5, 0(s7)
  # sanity: mepc must not be below the first instruction that ran with
  # interrupts enabled (the first one can land before the loop: the timer
  # was armed 40 clocks before, eleven instructions back)
  csrr t6, mepc
  la   t3, enabled
  blt  t6, t3, badmepc
  j    hret
badmepc:
  addi s9, s9, 1
hret:
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
