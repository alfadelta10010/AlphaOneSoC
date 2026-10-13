  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s10, 0                # the handler's count, before anything can interrupt
  li   s8, 0x02000000
  li   t1, 0x4000
  add  s7, s8, t1            # mtimecmp
  li   t1, 0xBFF8
  add  s6, s8, t1            # mtime
  sw   x0, 4(s7)
  # Timer period in mtime ticks; override with -DPERIOD=n to sweep it.
#ifndef PERIOD
#define PERIOD 50
#endif
  li   s5, PERIOD
  lw   t2, 0(s6)
  add  t2, t2, s5
  sw   t2, 0(s7)
  li   t0, 0x80
  csrs mie, t0
  li   t0, 0x8
  csrs mstatus, t0
  li   s0, 0
  li   s1, 20
loop:
  mul  t0, s0, s1            # 34-cycle multiply
  addi s0, s0, 1
  blt  s0, s1, loop
  li   t0, 0x80180000
  sw   s0, 0(t0)             # how many iterations completed
  sw   s10, 4(t0)            # interrupts serviced
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .align 2
handler:
  addi s10, s10, 1
  lw   t5, 0(s6)
  add  t5, t5, s5
  sw   t5, 0(s7)
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
