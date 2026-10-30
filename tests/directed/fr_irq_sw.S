# Fetch word reuse (WO-27): C1 is a c.sw to MSIP with MIE on, C2.. kept
# behind it. The interrupt lands on C1's successors wherever the pipeline
# takes it (the Spike trace cannot say where), so the check is the result:
# the run of compressed adds completes in full around the handler, once per
# round. The handler's first instructions are compressed.
#   x9 (s1)  total of the adds: 4 rounds x 8
#   x26 (s10) interrupts taken: 4
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
  mv   s0, gp
  li   a0, 1
  li   t0, 8
  csrw mie, t0
  li   s10, 0
  li   s1, 0
  csrsi mstatus, 8
  .set rnd, 0
  .rept 4
    .set rnd, rnd + 1
    ALIGN4
    .option rvc
    c.sw a0, 0(s0)
    c.addi s1, 1
    c.addi s1, 1
    c.addi s1, 1
    c.addi s1, 1
    c.addi s1, 1
    c.addi s1, 1
    c.addi s1, 1
    c.addi s1, 1
    .option norvc
    li   t0, rnd             # wait for this round's interrupt
2:  blt  s10, t0, 2b
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
  sw   zero, 0(gp)
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
