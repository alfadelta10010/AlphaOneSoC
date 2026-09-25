# U-mode straddling instructions of many kinds, incl. trapping ones, and
# MRET into a straddling target (mepc[1]=1). PMP entry0 NAPOT -1 RWX.
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  .option norvc
  la   t0, handler
  csrw mtvec, t0
  li   a0, -1
  csrw pmpaddr0, a0
  li   a0, 0x1f
  csrw pmpcfg0, a0
  li   s0, 0x80100000
  li   s1, 0x11
  sw   s1, 0(s0)
  sw   s0, 4(s0)
  li   s11, 0          # trap counter
  li   t1, 0x80
  csrw mstatus, t1
  la   t2, user
  csrw mepc, t2        # user is at a PC with bit1 = 1
  mret
  .balign 4
  .option rvc
  c.nop
user:
  .option norvc
  lw   a1, 4(s0)       # straddle, load
  lw   a2, 0(a1)       # straddle, load-use on address
  add  a3, a2, a2      # straddle, load-use on data
  mul  a4, a3, a3
  divu a5, a4, a3
  amoadd.w a6, a5, (s0)
  lw   a7, 0(s0)
  csrr t3, mstatus     # straddle, illegal from U -> cause 2
  addi t4, a7, 1
  ecall                # straddle ecall -> cause 8
  addi t5, t4, 1
  .option rvc
  c.addi t5, 1
  .option norvc
  beq  t5, t5, 1f      # 32-bit branch at bit1=0 now
  nop
1:
  .option rvc
  c.nop
  .option norvc
  jal  ra, 2f          # straddling jal
  nop
2:
  .option rvc
  c.nop
  .option norvc
  sw   t5, 8(s0)       # straddling store
  lw   t6, 8(s0)
  ebreak               # finish via handler
  .balign 4
handler:
  .option norvc
  csrr s2, mcause
  csrr s3, mepc
  csrr s4, mtval
  addi s11, s11, 1
  li   t0, 3
  beq  s2, t0, done
  addi s3, s3, 4
  csrw mepc, s3
  mret
done:
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
