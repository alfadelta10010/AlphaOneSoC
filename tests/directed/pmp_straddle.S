# U-mode executes a 32-bit insn at the last halfword of an X region; its upper
# half lies in the next (non-X) PMP region. Must be cause 1, mtval = 2nd half.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  la   t1, boundary
  srli t2, t1, 2
  csrw pmpaddr0, t2          # entry0 TOR [0, boundary) RWX
  li   t2, -1
  csrw pmpaddr1, t2          # entry1 TOR [boundary, top) R only
  li   t2, 0x0000090f
  csrw pmpcfg0, t2
  la   t0, umode
  csrw mepc, t0
  li   t0, 0x1800
  csrc mstatus, t0
  nop
  mret
umode:
  li   a0, 0x5a
  la   t1, straddle
  jr   t1
  .balign 4
  .skip 2
straddle:
  .option push
  .option norvc
  addi a0, x0, 0x123         # 32-bit insn starting 2 bytes before 'boundary'
  .option pop
  .balign 4, 0
  .equ boundary, straddle + 2
  nop
handler:
  csrr s0, mcause
  csrr s1, mepc
  csrr s2, mtval
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
