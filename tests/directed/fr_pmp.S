# Fetch word reuse (WO-27): C1 at 4k+2 is executable, C2 behind it at 4k+4
# is not (a locked TOR entry without X). C2 arrives in the kept halfword;
# the PMP check runs on its own address in EX, so it must fault with cause 1
# and mtval = 4k+4 exactly as if it had been fetched. M-mode, locked entries:
# [0,B) RWX, [B,B+4K) RW, [B+4K,4G) RWX (4 KiB is the PMP grain; B is a page boundary).
  .section .text.init
  .macro ALIGN4                # in rvc mode, so the linker keeps the alignment
    .option push
    .option rvc
    .balign 4
    .option pop
  .endm
  .globl rvtest_entry_point
rvtest_entry_point:
  csrw pmpcfg0, zero          # Spike resets pmpcfg0 to NAPOT RWX, the core to OFF: start both from OFF (a pmpaddr write is logged as read back)
  .option norvc
  la   t0, handler
  csrw mtvec, t0
  la   t0, blk
  addi t0, t0, 8             # B = blk + 8
  srli t1, t0, 2
  csrw pmpaddr0, t1
  addi t1, t1, 0x400         # + 4 KiB, in pmpaddr units
  csrw pmpaddr1, t1
  li   t1, 0x3fffffff
  csrw pmpaddr2, t1
  li   t1, 0x008f8b8f        # e2: L|TOR|RWX, e1: L|TOR|RW, e0: L|TOR|RWX
  csrw pmpcfg0, t1
  li   s10, 0
  j    blk
  ALIGN4
handler:
  csrr s2, mcause
  csrr s3, mepc
  csrr s4, mtval
  addi s10, s10, 1
  la   t0, after
  csrw mepc, t0
  mret
  # blk has to end 8 bytes before a page boundary: B = blk + 8 is the start of
  # the no-X page.
  .section .text.fr,"ax",@progbits
  .option push
  .option rvc
  .balign 4096
  .skip 4088
  .option pop
blk:
  .option rvc
  c.nop
  c.nop
  c.nop
c1:
  c.li a1, 5                 # blk+6: executable
c2:
  c.li a2, 6                 # blk+8 = B: no X -> cause 1, mtval = B
  c.li a3, 7
  .option push
  .option rvc
  .balign 4096               # padding sits in the no-X window and never runs
  .option pop
after:                       # B+4K
  addi s11, zero, 9
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
