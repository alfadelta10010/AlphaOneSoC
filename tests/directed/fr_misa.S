# Fetch word reuse (WO-27): with misa.C cleared every compressed instruction
# traps (cause 2, mtval = its 16 bits). C1 is fetched with C2 behind it; C1's
# trap must drop the kept C2 and C2 must not issue. The handler (32-bit,
# word aligned) sets C again and returns to C2.
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
  li   s4, 0
  li   a3, 0                 # c.addi reads these
  li   a4, 0
  ALIGN4
  csrci misa, 4              # next instruction is word aligned: C can go
  .option rvc
  c.li a0, 1
  c.li a1, 2
  c.li a2, 3
  .option norvc
  ALIGN4
  csrci misa, 4
  .option rvc
  c.addi a3, 4
  c.addi a4, 5
  .option norvc
  addi a5, zero, 6
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  ALIGN4
handler:
  csrsi misa, 4
  csrr s2, mcause
  csrr s3, mtval
  csrr t0, mepc
  addi t0, t0, 2
  csrw mepc, t0
  addi s4, s4, 1
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
