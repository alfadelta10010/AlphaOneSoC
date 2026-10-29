# Fetch word reuse (WO-27): a timer interrupt landing somewhere in a long
# run of compressed instructions. The run (six c.addi) loops on c.beqz until
# the handler sets a5. Wherever the interrupt lands, the handler returns to
# the next instruction, so the adds of the iteration it interrupted still
# complete: s0 is a multiple of 6.
#   x10 (a0)  s0 mod 6: 0     x15 (a5)  1     x26 (s10)  1
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
  li   s5, 0x02004000        # mtimecmp
  li   s6, 0x0200bff8        # mtime
  li   s0, 0
  li   a5, 0
  li   s10, 0
  li   t0, -1
  sw   t0, 0(s5)
  sw   zero, 4(s5)
  lw   t1, 0(s6)
  addi t1, t1, 600
  sw   t1, 0(s5)             # mtimecmp = mtime + 600
  li   t0, 0x80
  csrw mie, t0
  csrsi mstatus, 8
  ALIGN4
loop:
  .option rvc
  c.addi s0, 1
  c.addi s0, 1
  c.addi s0, 1
  c.addi s0, 1
  c.addi s0, 1
  c.addi s0, 1
  c.beqz a5, loop
  .option norvc
  li   t0, 6
  remu a0, s0, t0
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  ALIGN4
handler:
  .option rvc
  c.li a5, 1
  c.li s2, 17
  .option norvc
  li   t0, -1
  sw   t0, 4(s5)             # mtimecmp = far away
  addi s10, s10, 1
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
