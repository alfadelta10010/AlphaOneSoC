# Timer interrupts under load. From the design review of 2026-09-26, V7.
#
# The same compute loop -- M ops, loads and stores of every width to PSRAM A
# and B, an AMO, and calls to 32-bit instructions that straddle a 1 KB PSRAM
# page (0x800033FE) and the A -> B chip boundary (0x807FFFFE) -- runs twice:
# once with interrupts off, then with a timer interrupt every 2000-2224
# clocks whose handler also loads and stores PSRAM. An interrupt must not
# change the result, so the two checksums must match. At QSPI speed that is
# about 57 interrupts landing on every kind of access; with fast memory, a
# few.
#
# DUT-only: the timer counts clocks, Spike counts instructions. Results:
#   x21 (s5) = checksum, interrupts off (Spike's value for the same loop)
#   x25 (s9) = checksum off - checksum on, 0
#   x9  (s1) = 1 if interrupts were taken and every one had mcause
#              0x80000007 (the handler poisons x27, the count, otherwise)
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s8, 0x0200BFF8         # &mtime
  li   s7, 0x02004000         # &mtimecmp
  li   s11, 0                 # interrupts taken
  li   s10, 0x80600000        # handler scratch (PSRAM A)
  li   t0, -1
  sw   t0, 4(s7)
  call body
  mv   s5, s2                 # checksum, interrupts off
  lw   t2, 0(s8)
  li   t1, 2000
  add  t2, t2, t1
  sw   t2, 0(s7)
  sw   zero, 4(s7)
  li   t1, 0x80
  csrs mie, t1
  csrsi mstatus, 8
  call body
  csrci mstatus, 8
  mv   s6, s2                 # checksum, interrupts on
  li   t0, -1
  sw   t0, 4(s7)
  sub  s9, s5, s6
  li   t1, 0x1000
  sltu s1, s11, t1            # never poisoned
  snez t0, s11                # and at least one taken
  and  s1, s1, t0
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b

body:
  mv   s0, ra
  li   s1, 40
  li   s2, 0
  li   s3, 0x80400000         # PSRAM A
  li   s4, 0x80C00000         # PSRAM B
  li   t4, 3
  li   t5, 5
loop:
  call f
  call g
  mul  t0, s1, s1
  addi t0, t0, 123
  divu t1, t0, s1
  li   t6, 7
  rem  t2, t0, t6
  sw   t0, 0(s3)
  lw   t3, 0(s3)
  sh   t1, 2(s4)
  lhu  t6, 2(s4)
  sb   t2, 1(s4)
  lbu  a0, 1(s4)
  li   a1, 9
  amoadd.w a2, a1, (s3)
  lw   a3, 0(s3)
  add  s2, s2, t3
  xor  s2, s2, t6
  add  s2, s2, t2
  add  s2, s2, a0
  add  s2, s2, a2
  xor  s2, s2, a3
  add  s2, s2, t4
  slli t4, t4, 1
  xori t4, t4, 0x55
  addi s3, s3, 4
  addi s4, s4, 4
  addi s1, s1, -1
  bnez s1, loop
  mv   ra, s0
  ret

  .align 2
handler:
  addi s11, s11, 1
  csrr a6, mcause
  li   a7, 0x80000007
  beq  a6, a7, 2f
  li   s11, 0x1000            # wrong cause poisons the count
2:
  sw   s11, 0(s10)
  lw   a6, 0(s10)
  addi s10, s10, 4
  lw   a7, 0(s8)
  andi a6, s11, 7
  slli a6, a6, 5
  addi a6, a6, 2000
  add  a7, a7, a6
  li   a6, -1
  sw   a6, 4(s7)
  sw   a7, 0(s7)
  sw   zero, 4(s7)
  mret

  .section .fpage, "ax"
  .option rvc
f: c.nop
  .option norvc
  mul  t4, t4, t5             # at 0x800033FE: straddles a 1 KB page
  addi t4, t4, 1
  ret
  .section .gpage, "ax"
  .option rvc
g: c.nop
  .option norvc
  mul  t5, t5, t4             # at 0x807FFFFE: straddles PSRAM A -> B
  andi t5, t5, 0x3ff
  addi t5, t5, 3
  ret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
