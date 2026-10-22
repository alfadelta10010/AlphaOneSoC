# Reset in the middle of a program, 160 times. Hunts state a reset fails to
# clear: privilege mode (FC80), a WFI wait (FC81), the LR reservation (FC82),
# an AMO's second phase (FC83), a store in WB (FC84), the instruction in EX
# (FC85). Spec: privileged 3.4 (reset state: M-mode, mstatus MIE/MPRV 0, misa
# maximal, no load reservation, pc = reset vector, PMP A and L 0); CPU ref 6.1
# (mstatus 0), 7.2 (misa 0x40101105), 7.3 (mtvec 0), 6.3 (PMP entries OFF
# after reset, L clears only at reset), 9.3 (reset clears the reservation),
# 4 (mtimecmp resets to all ones, msip to 0). x1-x31 are not reset (CPU ref
# 14), so nothing is carried in registers across a reset. Not checked, as
# nothing specifies them: mie, mcause, mscratch, mepc, counters.
#
# Expect mode, DUT only: Spike has no reset. Needs tb_rivercore's +RESETS,
# +RESET_AT, +RESET_STRIDE: memory keeps its contents across them, so boots
# are counted in memory. Scratch words outside the image, zero at first:
#   N boot count, BAD failed checks, CHK check sections completed,
#   P PMP probe word, R reservation word, M store target, A AMO target.
#
# Every boot: n = N; N = n + 1. If n > 0 the reset checks run, then n == 160
# finishes and any other n runs the workload: M-mode setup (locked PMP entry
# denying M-mode loads of P, misa.C cleared, msip = 1, the timer armed, mie =
# MTIE), then a U-mode loop LR, DIV, SW, AMO, ECALL that runs until the next
# reset. (WFI is a NOP in U-mode on this core, so the ECALL's handler does the
# WFI in M-mode, where it waits for the timer.) The loop's period must stay
# below 160 cycles: then 160 resets one cycle apart land on every cycle of one
# period.
#
# Results: x10 = BAD (0), x11 = n (160), x12 = CHK (160).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point

  .equ SCR,  0x80F00000
  .equ OFF_N,   0
  .equ OFF_BAD, 4
  .equ OFF_CHK, 8
  .equ OFF_P,   12
  .equ OFF_R,   16
  .equ OFF_M,   20
  .equ OFF_A,   24

  .macro FAIL inc
  lw   t6, OFF_BAD(s0)
  addi t6, t6, \inc
  sw   t6, OFF_BAD(s0)
  .endm
  .macro CHECK_EQ ra, rb
  beq  \ra, \rb, 1f
  FAIL 1
1:
  .endm

rvtest_entry_point:
  li   s0, SCR
  lw   s1, OFF_N(s0)
  addi t0, s1, 1
  sw   t0, OFF_N(s0)
  beqz s1, workload

  # ---- reset checks ----
  csrr t0, mstatus             # 1. mstatus == 0 (U-mode here traps to 0: hang)
  CHECK_EQ t0, zero
  csrr t0, mtvec               # 2. mtvec == 0, then count traps instead
  CHECK_EQ t0, zero
  la   t0, chk_trap
  csrw mtvec, t0
  csrr t0, misa                # 3. misa maximal again
  li   t1, 0x40101105
  CHECK_EQ t0, t1
  csrr t0, pmpcfg0             # 4. PMP entries off, unlocked
  CHECK_EQ t0, zero
  lw   t0, OFF_P(s0)           # 5. P readable (a locked entry would deny it)
  addi s2, s0, OFF_R           # 6. no reservation: SC fails, R unchanged
  lw   t3, 0(s2)
  li   t1, 0x5a5a
  sc.w t4, t1, (s2)
  lw   t5, 0(s2)
  bnez t4, 2f
  FAIL 1
2:
  CHECK_EQ t3, t5
  csrr t0, mip                 # 7. no MSIP, no MTIP
  andi t0, t0, 0x88
  CHECK_EQ t0, zero
  lw   t0, OFF_CHK(s0)         # 8. section completed
  addi t0, t0, 1
  sw   t0, OFF_CHK(s0)
  li   t0, 160
  beq  s1, t0, finish

workload:
  la   t0, wl_trap
  csrw mtvec, t0
  addi t0, s0, OFF_P
  srli t0, t0, 2
  csrw pmpaddr0, t0
  li   t0, -1
  csrw pmpaddr1, t0
  li   t0, 0x1f90              # e0 NA4 over P, locked, no RWX; e1 NAPOT RWX
  csrw pmpcfg0, t0
  csrr t0, misa
  andi t0, t0, -5              # clear C
  csrw misa, t0
  li   t1, 0x02000000
  li   t0, 1
  sw   t0, 0(t1)               # msip = 1 (mie.MSIE stays 0)
  li   t2, 0x0200C000
  li   t0, -1
  li   t3, 0x02004000
  sw   t0, 4(t3)               # mtimecmp hi first, no spurious match
  lw   t0, -8(t2)              # mtime
  addi t0, t0, 100
  sw   t0, 0(t3)
  sw   zero, 4(t3)
  li   t0, 0x80
  csrw mie, t0
  li   t0, 0x1800
  csrc mstatus, t0             # MPP = U
  li   t0, 0x200000
  csrc mstatus, t0             # TW = 0
  li   t2, 0x07654321
  li   t3, 13
  li   t5, 1
  addi a3, s0, OFF_R
  addi a4, s0, OFF_M
  addi a5, s0, OFF_A
  la   t0, uloop
  csrw mepc, t0
  mret

  .align 2
uloop:
  lr.w     t0, (a3)
  div      t1, t2, t3
  sw       t1, 0(a4)
  amoadd.w t4, t5, (a5)
  ecall
  j        uloop

  .align 2
wl_trap:
  csrr s2, mcause
  li   s3, 0x80000007
  bne  s2, s3, wl_notimer
  li   s4, 0x0200C000
  lw   s5, -8(s4)              # mtime
  addi s5, s5, 100
  li   s6, 0x02004000
  sw   s5, 0(s6)               # re-arm
  mret
wl_notimer:
  li   s3, 8
  bne  s2, s3, wl_other
  wfi                          # M-mode WFI: waits for the timer (MIE=0, so no trap)
  csrr s2, mepc
  addi s2, s2, 4
  csrw mepc, s2
  mret
wl_other:
  FAIL 0x400
  csrr s2, mepc
  addi s2, s2, 4
  csrw mepc, s2
  mret

  .align 2
chk_trap:
  lw   t6, OFF_BAD(s0)
  addi t6, t6, 0x100
  sw   t6, OFF_BAD(s0)
  csrr t6, mepc
  addi t6, t6, 4
  csrw mepc, t6
  mret

finish:
  lw   a0, OFF_BAD(s0)
  mv   a1, s1
  lw   a2, OFF_CHK(s0)
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
