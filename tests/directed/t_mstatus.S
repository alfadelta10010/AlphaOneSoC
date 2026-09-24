  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   t1, -1
  csrw mstatus, t1
  csrr s0, mstatus          # DUT 0x1888 ; Spike 0x221888 (MPRV+TW)
  # try to set only MPRV
  li   t1, 0x00020000
  csrw mstatus, t1
  csrr s1, mstatus
  # try to set only TW
  li   t1, 0x00200000
  csrw mstatus, t1
  csrr s2, mstatus
  # MPP=01 legalization
  li   t1, 0x00001800
  csrw mstatus, t1          # MPP=11
  li   t1, 0x00000800
  csrw mstatus, t1          # MPP=01 -> DUT keeps 11, Spike -> 00
  csrr s3, mstatus
  # mstatush existence
  csrr s4, 0x310
  li   t0, 0x80100000
  sw   s0,0(t0)
  sw   s1,4(t0)
  sw   s2,8(t0)
  sw   s3,12(t0)
  sw   s4,16(t0)
  sw   s11,20(t0)
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j 1b
  .align 2
handler:
  csrr s11, mcause
  csrr t6, mepc
  addi t6, t6, 4
  csrw mepc, t6
  li   s4, 0xdead
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
