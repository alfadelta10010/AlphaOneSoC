# Fetch word reuse (WO-27): compressed runs across the PSRAM's 1 KB page
# boundaries and across the boundary between its two chips (0x807FFFFE ->
# 0x80800000). A fetch at a page's last halfword is split in two reads and
# its upper half comes from the next page / chip; the kept halfword is that
# half. The runs start at an even and an odd halfword so that one pair
# sits on the boundary in each case. Each hop is a 32-bit jump to the next.
  .section .text.init
  .macro ALIGN4                # in rvc mode, so the linker keeps the alignment
    .option push
    .option rvc
    .balign 4
    .option pop
  .endm
  .globl rvtest_entry_point
rvtest_entry_point:
  .option norvc
  li   s0, 0
  la   t0, p1
  jr   t0
  .macro RUN n
    .rept \n
      .set k, k+1
      c.addi s0, (k & 15) + 1
    .endr
  .endm
  .set k, 0
  .section .page1,"ax",@progbits         # 0x800003F0: pairs (3F0,3F2) .. (3FC,3FE) (400,402)
p1:
  .option rvc
  RUN 12
  .option norvc
  la   t0, p2
  jr   t0
  .section .page2,"ax",@progbits         # 0x800007F2: the pair (7FE,800) is split
p2:
  .option rvc
  RUN 8
  .option norvc
  la   t0, p3
  jr   t0
  .section .page3,"ax",@progbits         # 0x807FFFC0: even start
p3:
  .option rvc
  RUN 12
  .option norvc
  la   t0, p4
  jr   t0
  .section .page4,"ax",@progbits         # 0x807FFFEA: odd start, chip A -> B split
p4:
  .option rvc
  RUN 11
  .option norvc
  la   t0, fin
  jr   t0
  .section .text
fin:
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
