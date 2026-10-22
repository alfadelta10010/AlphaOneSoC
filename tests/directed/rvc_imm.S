# Every RV32C format with its immediate bits exercised, through the
# pipeline (the C chapter): C.LW/C.SW offsets 4..124, C.LWSP/C.SWSP
# 4..252, C.ADDI16SP and C.ADDI4SPN over their ranges, C.LUI with only
# nzimm[17] set and with the low bits, C.LI/C.ADDI/C.ANDI at -32 and 31,
# the shifts by 31, C.BEQZ/C.BNEZ at +254, -256 and at offsets whose bit 4
# differs from the sign, C.J/C.JAL at +2046 and -2048; then the reserved
# encodings C.SLLI with shamt[5] = 1, C.ADDI16SP with nzimm = 0, C.LUI with
# nzimm = 0, C.LWSP rd = 0 and C.JR rs1 = 0 (illegal, mtval the 16 bits).
# s1 collects a bit per landing. The handler copies mcause and mtval into
# registers and skips the instruction, 2 or 4 bytes. Spike checks it all.
  .option rvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  la   t0, far
  jr   t0

  .section .text
  .balign 4
far:
  li   s1, 0
  li   s0, 0x80804000
  li   sp, 0x80805000
  li   a5, 0x0badcafe
  c.sw a5, 124(s0)
  c.lw a0, 124(s0)
  c.sw a5, 64(s0)
  c.lw a1, 64(s0)
  c.sw a5, 32(s0)
  c.sw a5, 16(s0)
  c.sw a5, 8(s0)
  c.sw a5, 4(s0)
  c.lw a2, 32(s0)
  c.lw a3, 16(s0)
  c.lw a4, 8(s0)
  lw   a0, 4(s0)
  c.swsp a5, 252(sp)
  c.lwsp a0, 252(sp)
  c.swsp a5, 128(sp)
  c.swsp a5, 64(sp)
  c.swsp a5, 32(sp)
  c.swsp a5, 4(sp)
  c.lwsp a1, 128(sp)
  c.lwsp a2, 64(sp)
  c.lwsp a3, 32(sp)
  c.lwsp a4, 4(sp)
  c.addi16sp sp, -512
  mv   a0, sp
  c.addi16sp sp, 496
  mv   a1, sp
  c.addi16sp sp, 32
  c.addi16sp sp, 64
  c.addi16sp sp, 16
  c.addi16sp sp, -96
  mv   a2, sp
  c.addi4spn a0, sp, 1020
  c.addi4spn a1, sp, 512
  c.addi4spn a2, sp, 256
  c.addi4spn a3, sp, 128
  c.addi4spn a4, sp, 64
  c.addi4spn a5, sp, 16
  c.addi4spn s0, sp, 8
  c.addi4spn s1, sp, 4
  li   s1, 0
  c.lui a0, 0xfffe0
  c.lui a1, 0x1f
  c.lui a2, 0x1
  c.lui a3, 0xfffff
  c.li  a0, -32
  c.li  a1, 31
  c.addi a0, -32
  c.addi a1, 31
  c.andi a0, -32
  c.andi a1, 31
  li   a2, 0x80000001
  mv   a3, a2
  mv   a4, a2
  c.srli a2, 31
  c.srai a3, 31
  c.slli a4, 31
  c.li  a0, 0
  c.beqz a0, b1                 # +254
  c.li  s1, 1
  .skip 250
b1:
  ori  s1, s1, 2
  c.bnez a2, b2                 # +16: bit 4 set, sign clear
  ori  s1, s1, 4
  ori  s1, s1, 8
  ori  s1, s1, 16
  c.nop
b2:
  ori  s1, s1, 32
  j    b3j
b3_target:
  ori  s1, s1, 64
  j    b3_done
  .skip 248
b3j:
  c.beqz a0, b3_target          # about -254
b3_done:
  ori  s1, s1, 128
  c.j  cj1                      # +2046
  .skip 2044
cj1:
  ori  s1, s1, 256
  j    cj2j
cj2_target:
  ori  s1, s1, 512
  j    cj2_done
  .skip 2040
cj2j:
  c.jal cj2_target              # about -2046
cj2_done:
  mv   s2, ra
  # reserved encodings
  .hword 0x1502                 # c.slli a0, 32: shamt[5] = 1
  .hword 0x6101                 # c.addi16sp sp, 0
  .hword 0x6281                 # c.lui t0, 0
  .hword 0x4002                 # c.lwsp x0, 0(sp)
  .hword 0x8002                 # c.jr x0
  .hword 0x0000                 # all zero
  mv   a0, s1
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .balign 4
handler:
  csrr t3, mcause
  csrr t4, mtval
  csrr t5, mepc
  lhu  t6, 0(t5)
  andi t6, t6, 3
  addi t5, t5, 2
  li   a6, 3
  bne  t6, a6, 2f
  addi t5, t5, 2
2:csrw mepc, t5
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
