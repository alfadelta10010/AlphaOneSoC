# pmpcfg R=0,W=1 is reserved (Priv 3.7.1: collective WARL, R=0 W=1 reserved).
# Then: U-mode store to a region whose entry was written R=0,W=1,X=0.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  .option norvc
  la   t0, handler
  csrw mtvec, t0
  li   t0, 0x80100000
  srli t0, t0, 2
  ori  t0, t0, 0x1ff        # NAPOT 4 KiB at 0x80100000
  csrw pmpaddr0, t0
  li   t0, -1
  csrw pmpaddr1, t0         # NAPOT everything
  li   t0, 0x00001f1a       # e0: NAPOT, W=1 R=0 X=0 ; e1: NAPOT RWX
  csrw pmpcfg0, t0
  csrr s0, pmpcfg0
  li   t1, 0x80
  csrw mstatus, t1
  la   t2, user
  csrw mepc, t2
  mret
  .balign 4
user:
  li   s1, 0x80100000
  li   s2, 0x55
  sw   s2, 0(s1)            # U-mode store to the W-only region
  ecall
  .balign 4
handler:
  csrr s3, mcause
  csrr s4, mtval
  li   t0, 0x80100000
  lw   s5, 0(t0)
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
