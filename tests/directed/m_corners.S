# Every M instruction and every register shift on a grid of boundary
# operands, through the pipeline: 0, 1, -1, INT_MIN, INT_MAX, 2, -2 and an
# ordinary value, each as dividend and as divisor. That is x/0 for every x
# (quotient -1, remainder x, the dividend's sign included), INT_MIN/-1
# (INT_MIN, remainder 0), the MULH/MULHSU/MULHU signedness at both ends, and
# shift amounts whose bits above [4:0] are set (they must be ignored). The
# M chapter of the Unprivileged ISA defines every result; Spike checks each
# one in the trace. The operands come from a table, loaded just before the
# M ops use them, and each result is used straight away, so the load-use and
# use-hazard waits around a 34- or 36-cycle operation are in the path too.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   s1, 0
  la   s2, pairs
  la   s3, pairs_end
next:
  lw   a0, 0(s2)
  lw   a1, 4(s2)
  mul    a2, a0, a1
  mulh   a3, a0, a1
  mulhsu a4, a0, a1
  mulhu  a5, a0, a1
  div    a6, a0, a1
  divu   a7, a0, a1
  rem    t0, a0, a1
  remu   t1, a0, a1
  sll    t2, a0, a1
  srl    t3, a0, a1
  sra    t4, a0, a1
  xor    s1, s1, a2
  add    s1, s1, a6
  xor    s1, s1, t0
  add    s1, s1, t4
  addi   s2, s2, 8
  bltu   s2, s3, next
  # immediate shifts by 0 and 31 of the same values
.irp a, 0x80000000, 0x7fffffff, -1, 1
  li   a0, \a
  slli t2, a0, 31
  srli t3, a0, 31
  srai t4, a0, 31
  slli t5, a0, 0
  srai t6, a0, 0
.endr
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .data
  .balign 4
pairs:
.irp a, 0, 1, -1, 0x80000000, 0x7fffffff, 2, -2, 0x12345678
  .irp b, 0, 1, -1, 0x80000000, 0x7fffffff, 2, -2, 0x12345678
    .word \a, \b
  .endr
.endr
pairs_end:

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
