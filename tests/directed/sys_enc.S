# Reserved SYSTEM and MISC-MEM encodings must raise an illegal-instruction
# exception (cause 2, mtval the encoding), and the legal neighbours must
# not: ECALL/EBREAK/MRET/WFI with a nonzero rd or rs1 field, an MRET-family
# funct7 with another rs2, SRET with no S-mode, MISC-MEM funct3 010/011
# (no Zicbom); CSR immediates with zimm[4] set; a read of a read-only CSR
# (CSRRS/CSRRSI with x0 / uimm 0) versus a write to one; from U-mode, MRET
# and an M-level CSR. The handler copies mcause and mtval into registers
# and skips the instruction, so the trace shows each verdict and Spike
# checks it.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   t0, -1                   # PMP: everything RWX for U
  csrw pmpaddr0, t0
  li   t0, 0x1f
  csrw pmpcfg0, t0
  .word 0x000000f3              # ecall, rd = x1
  .word 0x00008073              # ecall, rs1 = x1
  .word 0x001000f3              # ebreak, rd = x1
  .word 0x00108073              # ebreak, rs1 = x1
  .word 0x302000f3              # mret, rd = x1
  .word 0x30208073              # mret, rs1 = x1
  .word 0x30300073              # funct7 0011000, rs2 = 3: reserved
  .word 0x10200073              # sret, no S-mode
  .word 0x105000f3              # wfi, rd = x1
  .word 0x10508073              # wfi, rs1 = x1
  .word 0x0000200f              # MISC-MEM funct3 010
  .word 0x0000300f              # MISC-MEM funct3 011
  csrrwi a1, mscratch, 31       # zimm with bit 4 set
  csrrsi a2, mscratch, 16
  csrrci a3, mscratch, 17
  csrr   a4, mscratch
  csrrs  a5, mhartid, x0        # reading a read-only CSR: no trap
  csrrsi a6, mvendorid, 0
  csrrw  x0, mhartid, a1        # writing one: trap
  csrrci a7, mvendorid, 1
  csrrs  s2, marchid, a1
  # to U-mode
  la   t0, ucode
  csrw mepc, t0
  li   t0, 0x1800
  csrc mstatus, t0
  mret
ucode:
  mret                          # illegal in U-mode
  csrr s3, mstatus              # M-level CSR from U: illegal
  csrr s4, mscratch
  csrr s5, cycle                # mcounteren = 0: illegal too
  ecall                         # back to M, done
  j    .

  .balign 4
handler:
  csrr t3, mcause
  csrr t4, mtval
  li   t5, 8
  beq  t3, t5, finish
  csrr t5, mepc
  addi t5, t5, 4
  csrw mepc, t5
  mret
finish:
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
