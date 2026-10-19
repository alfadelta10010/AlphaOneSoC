# U-mode takes an M-mode interrupt whatever mstatus.MIE is (Priv 3.1.6.1:
# interrupts for a higher privilege are always globally enabled). An MSI is
# made pending and enabled in mie while MIE = 0, so M-mode never takes it;
# the MRET to U-mode leaves MIE = 0 (MPIE was 0), and the interrupt must be
# taken at the first U-mode instruction. The handler reads mcause (MSI),
# mtval (0 for an interrupt, Priv 3.1.16), mepc (that first instruction)
# and mstatus (MPP = U, MPIE = 0), clears msip, and returns; U-mode then
# finishes with an ECALL. Spike checks every value.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   t0, -1                   # PMP: everything RWX for U
  csrw pmpaddr0, t0
  li   t0, 0x1f
  csrw pmpcfg0, t0
  li   t0, 0x02004000           # mtimecmp = -1, so MTIP is 0 on both models
  li   t1, -1                   # (their reset values differ)
  sw   t1, 4(t0)
  sw   t1, 0(t0)
  li   s1, 0x02000000           # CLINT msip
  li   t0, 8
  csrw mie, t0                  # MSIE
  li   t1, 1
  sw   t1, 0(s1)                # pending; M-mode with MIE = 0 does not take it
  nop
  nop
  csrr s2, mip
  la   t0, ucode
  csrw mepc, t0
  li   t0, 0x1880
  csrc mstatus, t0              # MPP = U, MPIE = 0
  mret
ucode:
  addi a0, zero, 1
  addi a1, zero, 2
  ecall
  j    .

  .balign 4
handler:
  csrr t3, mcause
  csrr t4, mtval
  csrr t5, mepc
  csrr t6, mstatus
  bgez t3, finish
  sw   zero, 0(s1)              # msip = 0
  mret
finish:
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
