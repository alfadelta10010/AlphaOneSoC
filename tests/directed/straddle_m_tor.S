# M-mode, locked TOR entries: [0,B) RWX, [B,B+8) RW (no X), [B+8,4G) RWX.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  .option norvc
  la   t0, handler
  csrw mtvec, t0
  la   t0, blk
  addi t0, t0, 8          # B = blk+8
  srli t1, t0, 2
  csrw pmpaddr0, t1
  addi t1, t1, 2
  csrw pmpaddr1, t1
  li   t1, 0x40000000
  csrw pmpaddr2, t1
  li   t1, 0x008f8b8f     # e2: L|TOR|RWX, e1: L|TOR|RW, e0: L|TOR|RWX
  csrw pmpcfg0, t1
  csrr s0, pmpcfg0
  li   s1, 0x80100000
  lw   a0, 0(s1)
  li   s10, 0
  j    case1
  .balign 8
blk:
  .option rvc
  c.nop
  c.nop
  c.nop
case1:
  .option norvc
  addi a1, a0, 7          # at blk+6: hi half (blk+8) no-X -> cause 1, mtval=B
  .option rvc
  c.nop                   # blk+10 (no-X)
  .option norvc
  addi a2, a0, 9          # blk+12 .. blk+15 : lo in no-X (blk+14?) no: at blk+12
after:                    # blk+16 = B+8, executable
  addi a3, a0, 13
  la   t0, blk
  addi t0, t0, 14         # straddle at B+6: lo no-X, hi at B+8 X -> mtval = B+6
  jr   t0
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
