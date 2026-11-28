# U-mode jumps into a region PMP marks non-executable; the word there is a MUL.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  csrw pmpcfg0, zero          # Spike resets pmpcfg0 to NAPOT RWX, the core to OFF: start both from OFF (a pmpaddr write is logged as read back)
  la   t0, handler
  csrw mtvec, t0
  # entry0: TOR [0, noexec) RWX ; entry1: TOR [noexec, noexec+4K) R only ; entry2: TOR [.., top) RWX
  # (noexec starts a page: 4 KiB is the PMP grain)
  la   t1, noexec
  srli t2, t1, 2
  csrw pmpaddr0, t2
  addi t2, t2, 0x400
  csrw pmpaddr1, t2
  li   t2, 0x3fffffff
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
  .section .text.nx,"ax",@progbits
  .balign 4096
noexec:
  mul  a2, a0, a1
  nop
  nop
  nop
  .section .text.init
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
