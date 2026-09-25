# U-mode jumps into a region PMP marks non-executable; the word there is a MUL.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  # entry0: TOR [0, noexec) RWX ; entry1: TOR [noexec, noexec+16) R only ; entry2: TOR [.., top) RWX
  la   t1, noexec
  srli t2, t1, 2
  csrw pmpaddr0, t2
  addi t2, t2, 4
  csrw pmpaddr1, t2
  li   t2, -1
  csrw pmpaddr2, t2
  li   t2, 0x000f090f        # cfg0=TOR|RWX, cfg1=TOR|R, cfg2=TOR|RWX
  csrw pmpcfg0, t2
  la   t0, umode
  csrw mepc, t0
  li   t0, 0x1800
  csrc mstatus, t0          # MPP=U
  mret
umode:
  la   t1, noexec
  jr   t1
  .align 4
noexec:
  mul  a2, a0, a1
  nop
  nop
  nop
  .align 4
handler:
  csrr a3, mcause
  csrr a4, mtval
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
