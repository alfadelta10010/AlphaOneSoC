# NAPOT must match only its own naturally aligned region. A 4 KB RWX NAPOT
# region at 0x80800000 must NOT cover the U-mode code at 0x800000xx, so the
# first U-mode fetch faults (cause 1) -- then a second entry covering the
# code makes the region's own data word loadable and the rest denied.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   t1, 0x202001ff        # NAPOT 0x80800000, 4 KB
  csrw pmpaddr0, t1
  li   t1, 0x1f              # A=NAPOT, RWX
  csrw pmpcfg0, t1
  la   t0, umode
  csrw mepc, t0
  li   t0, 0x1800
  csrc mstatus, t0           # MPP=U
  mret
umode:
  li   a2, 0x111             # must not execute
  ecall
  .balign 4
handler:
  csrr a4, mcause
  csrr a5, mtval
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
