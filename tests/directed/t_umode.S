  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  # exactly Linux head.S CONFIG_RISCV_M_MODE:
  li   a0, -1
  csrw pmpaddr0, a0
  li   a0, 0x1f              # PMP_A_NAPOT | PMP_R | PMP_W | PMP_X
  csrw pmpcfg0, a0
  csrr s0, pmpcfg0
  csrr s1, pmpaddr0
  # start_thread(): regs->status = SR_PIE (MPIE=1, MPP=0 -> U)
  li   t1, 0x00000080
  csrw mstatus, t1
  la   t2, user
  csrw mepc, t2
  mret
  .align 2
user:                        # now in U-mode with PMP RWX over everything
  li   s2, 0x5E12
  li   t3, 0x80100000
  lw   s3, 0(t3)             # U-mode load
  li   s4, 0x1234
  sw   s4, 0(t3)             # U-mode store
  lw   s5, 0(t3)
  ecall                      # cause 8 from U-mode
  .align 2
handler:
  csrr s6, mcause
  csrr s7, mstatus
  li   t0, 0x80180000
  sw   s0, 0(t0)
  sw   s1, 4(t0)
  sw   s3, 8(t0)
  sw   s5, 12(t0)
  sw   s6, 16(t0)
  sw   s7, 20(t0)
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
