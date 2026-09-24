# M-mode with locked PMP entries: a 32-bit instruction whose upper half is
# in a locked no-X region must fault (cause 1, mtval = upper half), the
# handler living below the boundary in the locked RWX region. The region
# above is RW so the handler can still reach tohost.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  la   t1, boundary
  srli t2, t1, 2
  csrw pmpaddr0, t2          # entry0 TOR [0, boundary) RWX, locked
  li   t2, -1
  csrw pmpaddr1, t2          # entry1 TOR [boundary, top) RW, no X, locked
  li   t2, 0x00008b8f
  la   t1, straddle
  csrw pmpcfg0, t2
  jr   t1
  .balign 4
handler:
  csrr s0, mcause
  csrr s1, mepc
  csrr s2, mtval
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .balign 4
  .skip 2
straddle:
  .option push
  .option norvc
  addi a0, x0, 0x123
  .option pop
  .balign 4, 0
  .equ boundary, straddle + 2
  nop
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
