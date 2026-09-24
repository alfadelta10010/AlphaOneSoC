  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s8, 0x02000000
  li   t1, 0x4000
  add  s7, s8, t1
  li   t1, 0xBFF8
  add  s6, s8, t1
  sw   x0, 4(s7)
  li   s5, 37                 # deliberately awkward period
  lw   t2, 0(s6)
  add  t2, t2, s5
  sw   t2, 0(s7)
  li   t0, 0x80
  csrs mie, t0
  li   t0, 0x8
  csrs mstatus, t0
  li   s0, 0
  li   s1, 2000
  li   s2, 0x80100000
  li   s10, 0                 # irq count
  li   s9, 0                  # MIE-lost count
loop:
  sw   s0, 0(s2)
  lw   t1, 0(s2)
  bne  t1, s0, bad
  sw   s0, 4(s2)
  lw   t1, 4(s2)
  bne  t1, s0, bad
  addi s0, s0, 1
  blt  s0, s1, loop
  j    rpt
bad:
  li   s9, 0xbad
rpt:
  csrr t3, mstatus            # MIE must still be 1 here
  andi t3, t3, 8
  li   t0, 0x80180000
  sw   s10, 0(t0)
  sw   s9,  4(t0)
  sw   t3,  8(t0)
  sw   s0, 12(t0)
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
