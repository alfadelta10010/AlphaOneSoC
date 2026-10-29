# Fetch word reuse (WO-27): a trap on C1 must drop the kept C2, and the
# MRET to C2 (mepc + 2) must fetch it again. C1 is c.ebreak, the reserved
# 0x0000, a misaligned c.lw and a c.lw to an unmapped address. The handler
# starts with two compressed instructions whose bits differ from C2's, and
# returns to mepc + 2.
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
  li   s0, 0x80000002        # misaligned c.lw address
  li   s1, 0x40000000        # nothing mapped
  li   s4, 0
  ALIGN4
  .option rvc
  c.ebreak
  c.li a0, 1
  c.li a1, 2
  .option norvc
  ALIGN4
  .option rvc
  .2byte 0x0000
  c.li a2, 3
  c.li a3, 4
  .option norvc
  ALIGN4
  .option rvc
  c.lw a4, 0(s0)
  c.li a5, 5
  c.li a6, 6
  .option norvc
  ALIGN4
  .option rvc
  c.lw a4, 0(s1)
  c.li a7, 7
  c.li a2, 8
  # the same four at 2 mod 4
  c.nop
  c.ebreak
  c.li a0, 9
  c.li a1, 10
  .option norvc
  ALIGN4
  .option rvc
  c.nop
  .2byte 0x0000
  c.li a2, 11
  c.li a3, 12
  c.nop
  c.lw a4, 0(s0)
  c.li a5, 13
  c.li a6, 14
  c.nop
  c.lw a4, 0(s1)
  c.li a7, 15
  c.li a2, 16
  .option norvc
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
  csrr t0, mepc
  addi t0, t0, 2
  csrw mepc, t0
  csrr t1, mcause
  csrr t2, mtval
  addi s4, s4, 1
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
