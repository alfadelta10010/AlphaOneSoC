# A PMP CSR write must govern the very next instruction. Lock a NAPOT entry
# (4 KiB, the grain; NA4 is not selectable) with no permissions over a data
# page, then load it immediately: the load must fault (cause 5) even in
# M-mode, because the entry is locked.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  csrw pmpcfg0, zero          # Spike resets pmpcfg0 to NAPOT RWX, the core to OFF: start both from OFF (a pmpaddr write is logged as read back)
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x80800000
  li   t0, 0x1234
  sw   t0, 0(s0)
  li   t1, 0x202001ff        # pmpaddr0 = NAPOT 4 KiB at 0x80800000
  csrw pmpaddr0, t1
  li   t2, 0x98              # L=1, A=NAPOT, RWX=000
  li   a0, 0
  csrw pmpcfg0, t2
  lw   a0, 0(s0)             # adjacent: must fault
  li   a1, 0xbad
  .balign 4
handler:
  csrr a2, mcause
  csrr a3, mtval
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
