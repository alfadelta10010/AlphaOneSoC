# Fetch word reuse (WO-27): a software interrupt taken on C1 with C2 kept
# (MSIP pending, MIE set by the csrsi right before C1: C1 is the first
# instruction that sees it). The interrupt drops the kept halfword; the
# handler starts with compressed instructions whose bits differ from C2's;
# after MRET the trace must run C1, then C2 again. Four rounds, C1 at an
# even and an odd halfword.
  .section .text.init
  .macro ALIGN4                # in rvc mode, so the linker keeps the alignment
    .option push
    .option rvc
    .balign 4
    .option pop
  .endm
  .globl rvtest_entry_point
rvtest_entry_point:
  .option norvc
  la   t0, handler
  csrw mtvec, t0
  li   gp, 0x02000000
  li   t0, 8
  csrw mie, t0               # MSIE
  li   s10, 0
  li   s0, 0
  .set rnd, 0
  .rept 4
    .set rnd, rnd + 1
    li   t0, 1
    sw   t0, 0(gp)           # msip = 1 (MIE = 0: masked)
    lw   t1, 0(gp)
    ALIGN4
    .if rnd & 1
      .option rvc
      c.nop
      .option norvc
    .endif
    csrsi mstatus, 8         # the interrupt is taken on the next instruction
    .option rvc
    c.addi s0, rnd
    c.addi s0, rnd + 4
    c.addi s0, rnd + 8
    c.addi s0, rnd + 12
    .option norvc
    csrci mstatus, 8
  .endr
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  ALIGN4
handler:
  .option rvc
  c.li s2, 17
  c.li s3, 18
  .option norvc
  csrr s4, mcause
  csrr s5, mepc
  sw   zero, 0(gp)           # clear msip
  lw   t3, 0(gp)
  addi s10, s10, 1
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
