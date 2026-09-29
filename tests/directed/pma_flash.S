# Flash (0x2000_0000) is read-only and has no reservation set: LR is a load
# access fault (5); SC, AMO and stores of every width, compressed included,
# are store/AMO access faults (7), each with mtval = the address; a plain
# load succeeds (it adds no cause). LR/SC on PSRAM succeed. DUT only: Spike
# maps the flash window as ordinary RAM, so every one of these succeeds
# there. What the load reads is not checked: the flash's contents belong to
# the testbench (erased flash reads 0xFF, the models' reads 0).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x20000000         # flash
  li   s1, 0x80003000         # PSRAM
  li   t2, 0x55
  li   a4, 0x55               # c.sw needs a register in x8-x15
  li   s2, 0                  # causes, one nibble per trap, oldest highest
  li   s4, 0                  # traps whose mtval was not the flash address
  lr.w t1, (s0)               # 5
  sc.w t1, t2, (s0)           # 7
  amoadd.w t1, t2, (s0)       # 7
  sw   t2, 0(s0)              # 7
  sh   t2, 0(s0)              # 7
  sb   t2, 0(s0)              # 7
  .option push
  .option rvc
  c.sw a4, 0(s0)              # 7
  c.nop                       # keeps what follows 4-byte aligned
  .option pop
  lw   t3, 0x100(s0)          # fine: no trap
  lr.w t1, (s1)
  sc.w t5, t2, (s1)           # t5 = 0: success
  j    done
  .align 2
handler:
  csrr a0, mcause
  slli s2, s2, 4
  or   s2, s2, a0
  csrr a1, mtval
  beq  a1, s0, 1f
  addi s4, s4, 1
1:csrr a2, mepc
  lhu  a3, 0(a2)              # skip the faulting instruction: 2 or 4 bytes
  andi a3, a3, 3
  li   a5, 3
  addi a2, a2, 2
  bne  a3, a5, 2f
  addi a2, a2, 2
2:csrw mepc, a2
  mret
done:
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
2: j 2b
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
