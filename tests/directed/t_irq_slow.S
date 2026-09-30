# Machine timer interrupts with a period long enough for a QSPI-speed
# handler (3000 clocks; the fast-memory timer tests use 40 and are skipped in
# the SoC run). Three interrupts are taken, each with mcause 0x80000007 and
# mepc inside the wait loop. DUT only: the timer counts clocks, Spike counts
# instructions.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x02000000
  li   s2, 0                  # interrupts taken
  li   s4, 0                  # interrupts with the wrong cause or mepc
  li   t1, 0x4000
  add  s7, s0, t1             # &mtimecmp
  li   t1, 0xBFF8
  add  s8, s0, t1             # &mtime
  li   t3, -1
  sw   t3, 4(s7)              # hi first, so no spurious match on the way
  lw   t2, 0(s8)
  li   t1, 3000
  add  t2, t2, t1
  sw   t2, 0(s7)
  sw   zero, 4(s7)
  li   t1, 0x80
  csrs mie, t1
  csrsi mstatus, 8
wait_loop:
  li   t1, 3
  blt  s2, t1, wait_loop
wait_end:
  csrci mstatus, 8
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
2: j 2b
  .align 2
handler:
  addi s2, s2, 1
  csrr a0, mcause
  li   t6, 0x80000007
  bne  a0, t6, bad
  csrr a1, mepc
  la   t6, wait_loop
  bltu a1, t6, bad
  la   t6, wait_end
  bgeu a1, t6, bad
  j    rearm
bad:
  addi s4, s4, 1
rearm:
  lw   t2, 0(s8)              # mtimecmp = mtime + 3000
  li   t6, 3000
  add  t2, t2, t6
  li   t6, -1
  sw   t6, 4(s7)
  sw   t2, 0(s7)
  sw   zero, 4(s7)
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
