  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x80100000        # base
  li   s1, 0                 # loop counter
  li   s2, 64                # iterations
  li   s3, 0x01234567        # seed
loop:
  # pseudo-random-ish value
  slli t0, s3, 5
  xor  s3, s3, t0
  srli t0, s3, 7
  xor  s3, s3, t0
  add  t1, s0, s1            # addr = base + i (byte)
  sb   s3, 0(t1)
  lbu  t2, 0(t1)
  andi t3, s3, 0xff
  bne  t2, t3, fail
  # halfword at base+256+2i
  slli t4, s1, 1
  add  t4, t4, s0
  addi t4, t4, 256
  sh   s3, 0(t4)
  lhu  t5, 0(t4)
  slli t6, s3, 16
  srli t6, t6, 16
  bne  t5, t6, fail
  # word at base+1024+4i
  slli t4, s1, 2
  add  t4, t4, s0
  addi t4, t4, 1024
  sw   s3, 0(t4)
  lw   t5, 0(t4)
  bne  t5, s3, fail
  # atomic on base+2048+4i
  slli t4, s1, 2
  add  t4, t4, s0
  li   a0, 2048
  add  t4, t4, a0
  sw   s3, 0(t4)
  li   t6, 0x11
  amoadd.w a0, t6, (t4)
  lw   a1, 0(t4)
  add  a2, s3, t6
  bne  a1, a2, fail
  bne  a0, s3, fail
  # lr/sc loop
1:lr.w  a3, (t4)
  addi  a4, a3, 3
  sc.w  a5, a4, (t4)
  bnez  a5, 1b
  lw    a6, 0(t4)
  addi  a7, a1, 3
  bne   a6, a7, fail
  # muldiv mixed in
  mul   t0, s3, s1
  div   t1, s3, s2
  rem   t2, s3, s2
  addi  s1, s1, 1
  blt   s1, s2, loop
  li    a0, 0                # pass
  j     done
fail:
  li    a0, 1
done:
  li    t0, 0x80180000
  sw    a0, 0(t0)
  sw    s1, 4(t0)
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
handler:
  li a0, 0xbad
  j done
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
