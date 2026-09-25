  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  # --- mepc with misa.C=0: does the dump line match Spike? ---
  li   t1, 4
  csrc misa, t1            # clear C
  nop
  nop
  li   t2, 0x80000102
  csrw mepc, t2            # tb prints ...102 ; spike stores ...100
  nop
  csrr s0, mepc            # read back (non-forwarded)
  li   t1, 4
  csrs misa, t1            # set C again
  nop
  nop
  csrr s1, mepc            # with C back on: DUT should show bit1 retained
  # --- pmpcfg0 lock: second write must be ignored ---
  # pmpaddr0 is programmed first: its reset value differs between the two
  # models (0 here per spec, all ones on Spike), and the lock freezes it.
  csrw pmpaddr0, zero
  li   t3, 0x0000009f      # byte0: L=1, A=NAPOT(11), X=1,W=1,R=1  -> 0x9f
  csrw pmpcfg0, t3
  nop
  li   t4, 0x00000000
  csrw pmpcfg0, t4         # locked -> must be ignored; tb prints 0
  nop
  csrr s2, pmpcfg0
  # --- pmpaddr0 lock ---
  li   t5, 0x12345678
  csrw pmpaddr0, t5        # entry0 locked -> ignored
  nop
  csrr s3, pmpaddr0
  li   t0, 0x80100000
  sw   s0, 0(t0)
  sw   s1, 4(t0)
  sw   s2, 8(t0)
  sw   s3, 12(t0)
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
handler:
  csrr s11, mcause
  j 1b
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
