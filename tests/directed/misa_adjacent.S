# Every misa.C consumer must see a misa write in the very next instruction:
# the mepc read mask, compressed decode, and the branch-target alignment
# check. Assembled norvc so every address is exact; the compressed
# instructions are emitted as halfwords.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s2, 0
  la   t0, anchor
  addi t0, t0, 2
  csrw mepc, t0             # mepc = anchor+2 (bit 1 set)
  la   t1, anchor
  addi t1, t1, 2            # 2-aligned jump target
  csrci misa, 4             # C=0 (pc is 4-aligned, so accepted)
  csrr a0, mepc             # adjacent: bit 1 must read 0
  csrsi misa, 4             # C=1
  .hword 0x0905             # c.addi s2, 1 -- adjacent: must execute
  .hword 0x0001             # c.nop
  csrci misa, 4             # C=0
  jalr x0, 0(t1)            # adjacent: 2-aligned target -> cause 0 on the jalr
  li   s3, 0xbad
  .balign 4
anchor:
  nop
  li   s3, 0xbad2
  .balign 4
handler:
  csrr a2, mcause
  csrr a3, mepc
  csrr a4, mtval
  csrsi misa, 4
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
