# Every load and store width at every byte offset of a word, and the
# atomics at a halfword offset. Unpriv 2.6 / Priv 3.7: an aligned access
# completes; a misaligned one traps here (cause 4 load, 6 store/AMO, mtval
# the address) -- Spike is run trapping on misalignment as well. The bytes
# of the word under test all have their top bit set, so every LB/LH must
# sign-extend from the right bit at every offset (and LBU/LHU must not);
# byte and halfword stores into every lane are read back as whole words.
# The handler copies mcause and mtval into registers and skips the access,
# so the trace shows each trap and Spike checks it.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x80800000
  li   t1, 0x8091a2b3
  sw   t1, 0(s0)
  li   t1, 0x7f01627e
  sw   t1, 4(s0)
.irp off, 0, 1, 2, 3
  lb   a0, \off(s0)
  lbu  a1, \off(s0)
  lh   a2, \off(s0)
  lhu  a3, \off(s0)
  lw   a4, \off(s0)
  lb   a0, 4+\off(s0)
  lh   a2, 4+\off(s0)
.endr
  # stores into every lane, each word read back
  li   t1, 0xc5
  li   t2, 0xd6e7
.irp off, 0, 1, 2, 3
  sw   zero, 8(s0)
  sb   t1, 8+\off(s0)
  lw   a5, 8(s0)
  sw   zero, 12(s0)
  sh   t2, 12+\off(s0)
  lw   a6, 12(s0)
  sw   t1, 16+\off(s0)
  lw   a7, 16(s0)
.endr
  # atomics at a halfword offset: AMO and SC are cause 6, LR cause 4
  addi s1, s0, 2
  amoadd.w  a0, t1, (s1)
  amoswap.w a0, t1, (s1)
  lr.w      a0, (s1)
  sc.w      a0, t1, (s1)
  addi s1, s0, 1
  amoor.w   a0, t1, (s1)
  lw   a4, 0(s0)
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .balign 4
handler:
  csrr t3, mcause
  csrr t4, mtval
  csrr t5, mepc
  addi t5, t5, 4
  csrw mepc, t5
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
