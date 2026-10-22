# Immediates at the bits where a misplaced wire is invisible on small
# offsets (Unpriv 2.3): JAL and branch offsets whose bit 11 differs from
# the sign (+2048 forward, -2052 backward); load/store offsets whose bits
# 11 and 10 differ (+1536, -1536); JALR with an odd base, an odd offset
# and both (the target's bit 0 cleared, Unpriv 2.5); LUI/AUIPC with
# imm[12] set and the top bit set; BEQ/BNE on operands that differ only in
# bit 31. s1 collects a distinct bit for every landing, so a jump that
# lands elsewhere shows in the trace even where it lands on a nop. Spike
# checks every register write.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   s1, 0
  la   t0, far
  jr   t0

  .section .text
  .balign 4
.macro MARK bit
  li   t6, 1 << \bit
  or   s1, s1, t6
.endm
far:
  jal  ra, fwd1                  # +2048
  .skip 2044
fwd1:
  ori  s1, s1, 0x1
  beq  zero, zero, fwd2          # +2052 (bit 11 set, sign clear)
  .skip 2048
fwd2:
  ori  s1, s1, 0x2
  j    bj
bwd_target:
  ori  s1, s1, 0x4
  j    after_bwd
  .skip 2044
bj:
  jal  ra, bwd_target            # -2052: bit 11 clear, sign set
after_bwd:
  ori  s1, s1, 0x8
  li   a0, 1
  j    bb
bwd_br:
  ori  s1, s1, 0x10
  j    after_bwd_br
  .skip 2048
bb:
  bne  a0, zero, bwd_br          # -2056: bit 11 clear, sign set
after_bwd_br:
  ori  s1, s1, 0x20

  # load/store offsets with bit 11 != bit 10
  li   s0, 0x80801000
  li   t1, 0x13579bdf
  sw   t1, 1536(s0)
  sw   t1, -1536(s0)
  lw   a1, 1536(s0)
  lw   a2, -1536(s0)
  lb   a3, -1535(s0)
  lhu  a4, 1538(s0)
  sh   t1, -1534(s0)
  lw   a5, -1536(s0)

  # JALR: target = (rs1 + imm) & ~1
  la   t2, j1
  addi t2, t2, 1                 # odd base, offset 0
  jalr ra, 0(t2)
  ori  s1, s1, 0x40              # skipped if the jump goes where it should
j1:
  ori  s1, s1, 0x80
  la   t2, j2
  addi t2, t2, -1                # odd base, odd offset: an even sum
  jalr ra, 1(t2)
  ori  s1, s1, 0x100
j2:
  ori  s1, s1, 0x200
  la   t2, j3
  jalr t2, 0(t2)                 # rd == rs1: the target is the old value
j3:
  ori  s1, s1, 0x400
  la   t2, j4 + 1536
  jalr ra, -1536(t2)
  MARK 11
j4:
  MARK 12

  # U-type immediates
  lui   a1, 0x1
  lui   a2, 0x80000
  lui   a3, 0xfffff
  auipc a4, 0x1
  auipc a5, 0x80001

  # equality on a difference in bit 31 only
  li   a1, 0x80000000
  li   a2, 0
  beq  a1, a2, 1f
  MARK 13
1:bne  a1, a2, 2f
  MARK 14
2:li   a3, 0x80000005
  li   a4, 0x00000005
  beq  a3, a4, 3f
  MARK 15
3:blt  a3, a4, 4f
  MARK 16
4:bltu a4, a3, 5f
  MARK 17
5:mv   a0, s1
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
6: j 6b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
