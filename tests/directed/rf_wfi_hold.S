# The instruction behind a WFI is held in EX by wfi_active; while it is held,
# the register file must keep being read for that instruction, not for the
# one already fetched behind it. Here WFI wakes without a trap -- Linux's idle
# loop runs wfi with MIE = 0 and the next instruction (a ret, say) reads a
# register:
#   1. mie = 0: WFI is a NOP but still sets wfi_active for one cycle.
#   2. MTIE = 1, MIE = 0, MTIP already pending (mtimecmp = 0): wakes, no trap.
# Both adds must give 0xc (a0 + a1). The instruction fetched behind each reads
# other registers (t1, and x1 through the bits of its immediate), so a read
# address taken from the fetch while IF/EX holds gives 100 + 1000 instead.
# Found by the design review of the macro integration: wfi_active was the one
# hold term no functional test covered. DUT-only: Spike waits in a WFI with
# nothing enabled.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   a0, 5
  li   a1, 7
  li   t1, 100
  li   ra, 1000
  li   a2, 0
  li   a3, 0
  csrw mie, zero
  nop
  nop
  wfi
  add  a2, a0, a1
  addi t0, t1, 1
  nop
  li   s0, 0x02000000
  li   t2, 0x4000
  add  s1, s0, t2
  sw   zero, 4(s1)            # mtimecmp = 0: MTIP pending
  sw   zero, 0(s1)
  li   t2, 0x80
  csrs mie, t2                # MTIE=1, mstatus.MIE stays 0
  nop
  nop
  wfi
  add  a3, a0, a1
  addi t0, t1, 1
  nop
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
2: j 2b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
