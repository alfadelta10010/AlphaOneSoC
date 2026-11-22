# WO-76: interrupts with a held word. The machine timer fires (a) while a
# loop of M ops and shifts is running, so the interrupt is taken with a
# fetched word held behind the stalled M op, and (b) while the hart sits in
# WFI, where the instruction after the WFI's successor is fetched and held.
# DUT-only: the timer counts clocks. Registers:
#   x8  (s0) = loop iterations done, 60
#   x9  (s1) = loop checksum
#   x11 (a1) = errors seen by the handler (mepc outside the loop), 0
#   x12 (a2) = 1 if the handler ran at least once in the loop
#   x13 (a3) = mepc - after_wfi in (b), 0
#   x14 (a4) = 1 if the handler ran again for (b)
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s10, 0                 # interrupts taken
  li   s11, 0                 # handler errors
  li   s5, 4000               # timer period (mtime ticks)
  li   s8, 0x02000000
  li   t1, 0x4000
  add  s7, s8, t1             # mtimecmp
  li   t1, 0xBFF8
  add  s6, s8, t1             # mtime
  li   t3, -1
  sw   t3, 4(s7)
  lw   t2, 0(s6)
  add  t2, t2, s5
  sw   t2, 0(s7)
  sw   zero, 4(s7)
  li   t0, 0x80
  csrs mie, t0
  csrsi mstatus, 8
  li   s0, 0
  li   s1, 0
  li   a5, 13
  li   a6, 0x7ffff
lp:
  mul  t4, s0, a5
  addi s1, s1, 3
  div  t5, a6, a5
  xor  s1, s1, t4
  slli t6, s0, 29
  add  s1, s1, t5
  srli t6, t6, 28
  add  s1, s1, t6
  addi s0, s0, 1
  li   t0, 60
  blt  s0, t0, lp
lp_end:
  csrci mstatus, 8
  beqz s10, nz
  li   a2, 1
  j    nz2
nz:
  li   a2, 0
nz2:
  mv   a1, s11
  # (b) WFI with the timer armed
  mv   s9, s10
  li   t3, -1
  sw   t3, 4(s7)
  lw   t2, 0(s6)
  li   t1, 3000
  add  t2, t2, t1
  sw   t2, 0(s7)
  sw   zero, 4(s7)
  csrsi mstatus, 8
wfi1:
  wfi
after_wfi:
  addi t0, t0, 1
  addi t0, t0, 1
  csrci mstatus, 8
  la   t0, after_wfi
  sub  a3, s3, t0
  sub  a4, s10, s9
  sltu a4, zero, a4
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b

  .align 2
handler:
  addi s10, s10, 1
  csrr s3, mepc
  lw   s2, 0(s6)
  add  s2, s2, s5
  li   s4, -1
  sw   s4, 4(s7)
  sw   s2, 0(s7)
  sw   zero, 4(s7)
  # mepc must be inside the loop or at the one instruction after the WFI
  la   s2, lp
  bltu s3, s2, chk_wfi
  la   s2, lp_end
  bltu s3, s2, hret
chk_wfi:
  la   s2, after_wfi
  beq  s3, s2, hret
  la   s2, lp_end
  beq  s3, s2, hret
  addi s11, s11, 1
hret:
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
