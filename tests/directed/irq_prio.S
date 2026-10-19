# Interrupt priority, Priv 3.1.9: with MEI, MSI and MTI all pending and
# enabled, they are taken in the order MEI, MSI, MTI. All three are raised
# while MIE = 0 -- MEIP through the testbench's MEIP hook at 0x0200C000
# (tb/memory_model.v), MSIP through the CLINT's msip, MTIP by mtimecmp = 0
# -- and then MIE is set. Each handler run clears its own source and
# returns, so the next is taken at once. x10 collects the causes a byte at
# a time: 0x000b0307. x11 counts the interrupts: 3.
#
# Expect mode, not Spike: Spike has no device behind MEIP, so the MEIP hook
# cannot be compared. Skipped in the SoC run, which has no hook either.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   a0, 0
  li   a1, 0
  li   s1, 0x02000000           # msip
  li   s2, 0x0200c000           # MEIP hook
  li   s3, 0x02004000           # mtimecmp
  li   t0, 1
  sw   t0, 0(s1)                # MSIP
  sw   t0, 0(s2)                # MEIP
  sw   zero, 4(s3)              # mtimecmp = 0: MTIP
  sw   zero, 0(s3)
  li   t0, 0x888
  csrw mie, t0
  nop
  nop
  nop
  nop
  csrsi mstatus, 8              # all three taken from here
  nop
  nop
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .balign 4
handler:
  csrr t1, mcause
  andi t1, t1, 0xff
  slli a0, a0, 8
  or   a0, a0, t1
  addi a1, a1, 1
  li   t2, 11
  beq  t1, t2, mei
  li   t2, 3
  beq  t1, t2, msi
  li   t2, -1                   # MTI: mtimecmp back to all ones
  sw   t2, 4(s3)
  sw   t2, 0(s3)
  j    out
mei:
  sw   zero, 0(s2)
  j    out
msi:
  sw   zero, 0(s1)
out:
  nop                           # past MTIP's two-clock lag (CPU ref 8.4)
  nop
  nop
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
