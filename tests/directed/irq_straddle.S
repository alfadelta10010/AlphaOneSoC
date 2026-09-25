# Software interrupts landing on straddling 32-bit instructions while the
# upper-half PMP check is live (locked NAPOT entry, so M-mode pays the extra
# EX cycle too), in M-mode and on the first U-mode instruction after MRET.
# mepc must be the instruction's start.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  .option norvc
  la   t0, handler
  csrw mtvec, t0
  li   t0, -1
  csrw pmpaddr0, t0
  li   t0, 0x9f              # locked NAPOT RWX everything -> M-mode hi-phase active
  csrw pmpcfg0, t0
  li   s10, 0
  li   gp, 0x02000000
  li   t0, 1
  sw   t0, 0(gp)             # msip=1 (MIE=0, mie=0: masked)
  li   t0, 8
  csrw mie, t0               # MSIE
  lw   t1, 0(gp)
  j    m1
  .option rvc
  .balign 4
  c.nop
  .option norvc
m1:
  csrsi mstatus, 8           # straddles? no: this one aligned below
  addi a0, zero, 11          # straddling, interrupted here
  addi a1, zero, 12
  # U-mode case
  li   t0, 1
  sw   t0, 0(gp)             # msip=1 again (MIE=0 after trap)
  lw   t1, 0(gp)
  li   t1, 0x80              # MPIE=1 MPP=U
  csrw mstatus, t1
  la   t2, u1
  csrw mepc, t2
  mret
  .option rvc
  .balign 4
  c.nop
  .option norvc
u1:
  addi a2, zero, 13          # straddling first U instruction: interrupted
  addi a3, zero, 14
  ecall
  .option rvc
  .balign 4
  .option norvc
handler:
  csrr s2, mcause
  csrr s3, mepc
  csrr s4, mstatus
  addi s10, s10, 1
  sw   zero, 0(gp)           # clear msip
  lw   t3, 0(gp)
  li   t4, 3
  beq  s10, t4, done
  li   t4, 8
  beq  s2, t4, done
  li   t4, 0x80
  csrc mstatus, t4
  mret
done:
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
