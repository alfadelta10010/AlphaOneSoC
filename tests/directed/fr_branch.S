# Fetch word reuse (WO-27): a redirect must drop the kept halfword. Each
# branch below sits at a word boundary with a different compressed
# instruction behind it (the kept one); the target's bits differ from the
# kept ones, so a stale hit shows in the trace. c.beqz / c.bnez not taken
# keep the halfword (the next instruction is the sequential one).
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
  li   a5, 0
  li   s0, 0
  li   s1, 1
  # not taken: c.beqz a1 (a1 = 1), c.bnez a5 (a5 = 0), then compressed code
  li   a1, 1
  ALIGN4
  .option rvc
  c.beqz a1, 9f
  c.addi s0, 3
  c.bnez a5, 9f
  c.addi s0, 5
  c.addi s0, 7
  c.addi s0, 9
  .option norvc
9: addi s1, s1, 1
  # taken c.beqz, the kept C2 (c.li a0, 1) must not run; target has c.li a0, 2
  ALIGN4
  .option rvc
  c.beqz a5, 1f
  c.li a0, 1
  c.li a0, -1
1: c.li a0, 2
  c.li a2, 3
  .option norvc
  # taken c.bnez
  li   a4, 1
  ALIGN4
  .option rvc
  c.bnez a4, 1f
  c.li a0, 4
  c.li a0, -2
1: c.li a0, 5
  c.li a2, 6
  # c.j
  ALIGN4
  c.j  1f
  c.li a0, 7
  c.li a0, -3
1: c.li a0, 8
  c.li a2, 9
  # c.jal (links; target differs from the kept halfword)
  ALIGN4
  c.jal 1f
  c.li a0, 10
  c.li a0, -4
1: c.li a0, 11
  c.li a2, 12
  # c.jr and c.jalr
  .option norvc
  la   t0, 1f
  ALIGN4
  .option rvc
  c.jr t0
  c.li a0, 13
  c.li a0, -5
1: c.li a0, 14
  .option norvc
  la   t0, 1f
  ALIGN4
  .option rvc
  c.jalr t0
  c.li a0, 15
  c.li a0, -6
1: c.li a0, 16
  c.li a2, 17
  .option norvc
  # odd alignment: the branch is at 2 mod 4, kept halfword at 0 mod 4
  ALIGN4
  .option rvc
  c.nop
  c.beqz a5, 1f
  c.li a0, 18
  c.li a0, -7
1: c.li a0, 19
  c.li a2, 20
  .option norvc
  # a 32-bit branch whose target is the C2 of a C1/C2 pair: run the pair
  # through, then branch into its second half.
  li   s2, 0
  ALIGN4
pair1:
  .option rvc
  c.li a3, 21
tgt2:
  c.li a4, 22
  c.li a6, 23
  .option norvc
  addi s2, s2, 1
  li   t0, 2
  beq  s2, t0, 2f
  beq  zero, zero, tgt2
2:
  # a branch to .+2
  ALIGN4
  .option rvc
  c.j  1f
1: c.li a0, 24
  c.li a2, 25
  .option norvc
  # a 32-bit jal to the second half of a pair, kept halfword differs
  li   s3, 0
  ALIGN4
  .option rvc
  c.li a3, 26
tgt3:
  c.li a4, 27
  c.li a6, 28
  .option norvc
  addi s3, s3, 1
  li   t0, 2
  beq  s3, t0, 3f
  jal  zero, tgt3
3:
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
