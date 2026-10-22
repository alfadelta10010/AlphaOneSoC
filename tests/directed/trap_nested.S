# A trap taken inside a trap handler (Priv 3.1.6.1, 3.3.1): the second trap
# overwrites mepc/mcause/mtval, saves the handler's own MIE (0) in MPIE and
# its privilege (M) in MPP; its MRET returns to the handler in M-mode with
# MPP = U; the handler then restores the first trap's context by hand and
# returns to where that trap came from. Four pairs, each a different
# second cause:
#   M-mode ECALL (11)     -> illegal instruction (2) in the handler
#   U-mode ECALL (8)      -> EBREAK (3)
#   U-mode illegal (2)    -> load access fault (5), unmapped address
#   U-mode EBREAK (3)     -> load address misaligned (4)
# then a U-mode ECALL with a7 = 99 asks to finish in M-mode. Every CSR the
# handlers read lands in a register, so the trace shows each trap's mepc,
# mcause, mtval and mstatus, and Spike checks them. s0 collects every cause
# as a nibble, in the order taken.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0
  li   s1, 0                  # 0: outer trap, 1: inside the handler
  li   t0, -1                 # PMP entry 0: NAPOT over everything, RWX, so U may run
  csrw pmpaddr0, t0
  li   t0, 0x1f
  csrw pmpcfg0, t0
  ecall                       # 11 -> nested 2
  la   t0, ucode
  csrw mepc, t0
  li   t0, 0x1800
  csrc mstatus, t0            # MPP = U
  mret
ucode:
  ecall                       # 8  -> nested 3
  .word 0                     # 2  -> nested 5
  ebreak                      # 3  -> nested 4
  li   a7, 99
  ecall                       # 8, a7 = 99: finish in M-mode
  j    .
done:
  mv   a0, s0
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .balign 4
handler:
  csrr t1, mcause
  slli s0, s0, 4
  or   s0, s0, t1
  bnez s1, inner
  # outer trap: save its context, then trap again from here
  csrr s2, mepc
  csrr s3, mstatus
  csrr s4, mtval
  li   t2, 8
  bne  t1, t2, 2f
  li   t3, 99
  beq  a7, t3, finish
2:li   s1, 1
  li   t2, 11
  beq  t1, t2, n_illegal
  li   t2, 8
  beq  t1, t2, n_ebreak
  li   t2, 2
  beq  t1, t2, n_fault
  j    n_misaligned
n_illegal:
  .word 0                     # nested cause 2
  j    outer_ret
n_ebreak:
  ebreak                      # nested cause 3
  j    outer_ret
n_fault:
  li   t3, 0x40000000         # unmapped in both models
  lw   t4, 0(t3)              # nested cause 5
  j    outer_ret
n_misaligned:
  li   t3, 0x80800001
  lw   t4, 0(t3)              # nested cause 4
  j    outer_ret
outer_ret:
  csrr t5, mstatus            # after the inner MRET: MPP = U, MPIE = 1
  li   s1, 0
  csrw mstatus, s3            # the outer trap's MPP/MPIE again
  addi s2, s2, 4
  csrw mepc, s2
  mret
inner:
  # the second trap: its mepc is inside the handler, MPP = M
  csrr s5, mepc
  csrr s6, mstatus
  csrr s7, mtval
  addi s5, s5, 4
  csrw mepc, s5
  mret                        # back into the handler, in M-mode
finish:
  li   t0, 0x1800
  csrs mstatus, t0            # MPP = M
  la   t0, done
  csrw mepc, t0
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
