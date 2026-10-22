# PMP permissions of atomics and stores in U-mode (Priv 3.7.1: an access
# needs every permission it uses; an AMO reads and writes, an SC writes,
# an LR reads). Entry 0: NAPOT 4 KB at 0x80802000, R only. Entry 1: NAPOT
# 4 KB at 0x80803000, R+W. Entry 2: everything else, RWX. In the R-only
# page a load and an LR succeed, and an AMO, an SC and a store are store/AMO
# access faults (cause 7); in the R+W page all of them succeed. The handler
# copies mcause and mtval into registers and skips the access.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x80802000
  li   s1, 0x80803000
  li   t1, 0x11223344
  sw   t1, 0(s0)
  sw   t1, 0(s1)
  li   t0, 0x202009ff           # NAPOT 4 KB at 0x80802000
  csrw pmpaddr0, t0
  li   t0, 0x20200dff           # NAPOT 4 KB at 0x80803000
  csrw pmpaddr1, t0
  li   t0, -1
  csrw pmpaddr2, t0
  li   t0, 0x001f1b19           # entry 2 RWX, entry 1 RW, entry 0 R (all NAPOT)
  csrw pmpcfg0, t0
  la   t0, ucode
  csrw mepc, t0
  li   t0, 0x1800
  csrc mstatus, t0
  mret
ucode:
  li   t1, 5
  lw   a0, 0(s0)                # R: fine
  amoadd.w a1, t1, (s0)         # needs W: cause 7
  amoswap.w a1, t1, (s0)        # cause 7
  sw   t1, 4(s0)                # cause 7
  lr.w a2, (s0)                 # R: fine
  sc.w a3, t1, (s0)             # needs W: cause 7
  lw   a4, 0(s0)                # unchanged
  amoadd.w a5, t1, (s1)         # R+W: fine
  lr.w a6, (s1)
  sc.w a7, t1, (s1)             # succeeds
  lw   s2, 0(s1)
  ecall
  j    .

  .balign 4
handler:
  csrr t3, mcause
  csrr t4, mtval
  li   t5, 8
  beq  t3, t5, finish
  csrr t5, mepc
  addi t5, t5, 4
  csrw mepc, t5
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
