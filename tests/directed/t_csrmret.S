  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  # trap handler
  la   t0, handler
  csrw mtvec, t0

  # --- case 1: csrw mscratch immediately before mret ---
  li   t1, 0x11112222
  li   t2, 0x0
  la   t3, after1
  csrw mepc, t3
  li   t4, 0x1800          # MPP=M, MPIE=0, MIE=0
  csrw mstatus, t4
  csrw mscratch, t1        # <-- write that must survive
  mret
after1:
  csrr s0, mscratch        # expect 0x11112222

  # --- case 2: csrw mstatus immediately before mret ---
  la   t3, after2
  csrw mepc, t3
  li   t4, 0x1880          # MPP=M, MPIE=1, MIE=0
  csrw mstatus, t4
  mret
after2:
  csrr s1, mstatus         # expect MIE=1 (0x80 | ...)

  # --- case 3: csrw mepc immediately before mret ---
  la   t3, after3
  li   t4, 0x1800
  csrw mstatus, t4
  csrw mepc, t3
  mret
after3:
  csrr s2, mepc            # expect address of after3

  # --- control: nop between ---
  li   t1, 0x33334444
  la   t3, after4
  csrw mepc, t3
  csrw mscratch, t1
  nop
  mret
after4:
  csrr s3, mscratch        # expect 0x33334444

  j    done
handler:
  csrr s11, mcause
  j    done
done:
  # store results so they show in the trace
  li   a0, 0x80100000
  sw   s0, 0(a0)
  sw   s1, 4(a0)
  sw   s2, 8(a0)
  sw   s3, 12(a0)
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
