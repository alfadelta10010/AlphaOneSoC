  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   a0, 7
  li   a1, 9
  mul  a2, a0, a1          # <-- livelocks when (muldiv latency) % (IMEM_WAIT+1) != 0
  li   t0, 0x80100000
  sw   a2, 0(t0)
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
