# Fetch word reuse (WO-27): a compressed instruction's fetch brings in the
# halfword behind it, and the core keeps it for the next instruction. Every
# shape below must give Spike's trace whether or not the halfword is kept:
# a pair C1 C2 between two 32-bit instructions, aligned and shifted by a
# halfword; a 32-bit instruction that starts in the kept halfword (not
# kept); runs of 2..5 compressed instructions from an even and an odd
# halfword. Each compressed instruction writes a different value.
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
  li   s0, 0
  li   s1, 0
  .set k, 0
  .macro CRUN n
    .option rvc
    .rept \n
      .set k, k+1
      c.addi s0, (k & 15) + 1
    .endr
    .option norvc
    addi s1, s1, 7           # 32-bit separator
  .endm
  .macro ODD
    .option rvc
    c.nop                    # moves the next instruction to a 2 mod 4 address
    .option norvc
  .endm
  # 3.1 A(32) C1 C2 B(32), word aligned
  ALIGN4
  addi a0, zero, 1
  .option rvc
  c.li a1, 2
  c.li a2, 3
  .option norvc
  addi a3, zero, 4
  # 3.2 the same shifted by a halfword (A and B straddle)
  ALIGN4
  ODD
  addi a0, a0, 11
  .option rvc
  c.li a1, 12
  c.li a2, 13
  .option norvc
  addi a3, zero, 14
  # 3.3 C1 then a 32-bit instruction that starts in the kept halfword
  ALIGN4
  .option rvc
  c.li a4, 21
  .option norvc
  addi a5, zero, 22          # at 2 mod 4
  .option rvc
  c.li a6, 23
  .option norvc
  addi a7, zero, 24          # at 2 mod 4 again after the pair: not here
  # 3.4 runs of n compressed instructions, even and odd start
  ALIGN4
  CRUN 2
  CRUN 3
  CRUN 4
  CRUN 5
  ALIGN4
  ODD
  CRUN 2
  CRUN 3
  CRUN 4
  CRUN 5
  ALIGN4
  ODD
  CRUN 1
  CRUN 6
  CRUN 7
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
