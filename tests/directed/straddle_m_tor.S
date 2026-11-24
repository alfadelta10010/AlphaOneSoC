# M-mode, locked TOR entries at the core's 4 KiB PMP grain, B a page boundary:
# [0,B) RWX, [B,B+4K) RW (no X), [B+4K,4G) RWX. Two instructions straddle a
# bound: one at B-2 (upper half in the no-X page), one at B+4K-2 (lower half
# in the no-X page).
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  csrw pmpcfg0, zero          # Spike resets pmpcfg0 to NAPOT RWX, the core to OFF: start both from OFF (a pmpaddr write is logged as read back)
  .option norvc
  la   t0, handler
  csrw mtvec, t0
  la   t0, blk
  li   t2, 4096
  add  t0, t0, t2         # B = blk + 4096
  srli t1, t0, 2
  csrw pmpaddr0, t1
  addi t1, t1, 0x400      # + 4 KiB, in pmpaddr units
  csrw pmpaddr1, t1
  li   t1, 0x3fffffff     # TOR top: every page below 0xfffff000
  csrw pmpaddr2, t1
  li   t1, 0x008f8b8f     # e2: L|TOR|RWX, e1: L|TOR|RW, e0: L|TOR|RWX
  csrw pmpcfg0, t1
  csrr s0, pmpcfg0
  li   s1, 0x80100000
  lw   a0, 0(s1)
  li   s10, 0
  la   t0, case1
  jr   t0
  .section .text.sm,"ax",@progbits
  .balign 4096
blk:
  .skip 4094
case1:
  .option norvc
  addi a1, a0, 7          # at B-2: hi half (B) no-X -> cause 1, mtval = B
  .skip 4092
case2:
  .option norvc
  addi a2, a0, 9          # at B+4K-2: lo half no-X, hi half X -> cause 1, mtval = B+4K-2
after:                    # B+4K+2, executable
  addi a3, a0, 13
  la   t0, case2
  jr   t0
  .section .text.init
  .balign 4
handler:
  csrr s2, mcause
  csrr s3, mepc
  csrr s4, mtval
  addi s10, s10, 1
  li   t0, 2
  beq  s10, t0, done
  la   t0, after
  csrw mepc, t0
  li   t0, 0x1800
  csrs mstatus, t0
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
