# Fetch word reuse (WO-27): the kept C2 behind instructions that stay in EX
# for a long time or touch memory at SoC speed: a compressed shift by 31 (the
# serial shifter, nothing in flight to hide it behind), a load followed by
# its consumer (use_hazard), a load followed by a store (two data requests
# with no fetch between them).
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
  li   s0, 0x80002000
  li   t0, 0x8badf00d
  sw   t0, 0(s0)
  li   t0, 0x12345678
  sw   t0, 4(s0)
  mv   a2, s0
  li   a0, 0x80000001
  li   a1, 0x7ffffff1
  ALIGN4
  .option rvc
  c.srai a0, 31
  c.li a3, 1
  c.srli a1, 31
  c.li a4, 2
  c.slli a0, 31
  c.li a5, 3
  c.slli a1, 5
  .option norvc
  ALIGN4
  .option rvc
  c.nop
  c.lw a0, 0(a2)
  c.add a1, a0
  c.lw a3, 4(a2)
  c.sw a3, 8(a2)
  c.lw a4, 8(a2)
  c.add a4, a1
  c.sw a4, 12(a2)
  c.lw a5, 12(a2)
  c.sub a5, a4
  c.li a6, 9
  .option norvc
  ALIGN4
  .option rvc
  c.lw a0, 0(a2)
  c.add a1, a0
  c.lw a3, 4(a2)
  c.sw a3, 8(a2)
  c.srai a3, 31
  c.li a7, 4
  c.addi a7, 1
  .option norvc
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
