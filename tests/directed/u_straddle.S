# U-mode code full of 32-bit instructions at 2-aligned addresses, so every
# one straddles a word boundary and takes the upper-half PMP check. They
# must all execute normally: loads, a load-use pair, a mul, a taken branch,
# an AMO, a jalr. PMP is Linux's NAPOT -1 RWX entry.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   a0, -1
  csrw pmpaddr0, a0
  li   a0, 0x1f
  csrw pmpcfg0, a0
  la   t0, umode
  csrw mepc, t0
  li   t0, 0x1800
  csrc mstatus, t0
  mret
  .balign 4
umode:
  c.nop                        # everything below starts at a 2-aligned address
  li   s0, 0x81000000
  li   t1, 0x12345678
  sw   t1, 0(s0)
  lw   t2, 0(s0)
  addi t3, t2, 1               # load-use
  li   a1, 7
  li   a2, 9
  mul  a3, a1, a2
  divu a4, t1, a1
  amoadd.w a5, a1, (s0)
  lw   a6, 0(s0)
  beq  a1, a1, 1f
  li   a7, 0xbad
1:
  la   t4, 2f
  jalr x0, 0(t4)
  li   a7, 0xbad2
2:
  c.nop
3:
  addi s1, s1, 1
  li   t5, 5
  blt  s1, t5, 3b
  ecall
  .balign 4
handler:
  csrr s2, mcause
  csrr s3, mepc
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
4: j 4b
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
