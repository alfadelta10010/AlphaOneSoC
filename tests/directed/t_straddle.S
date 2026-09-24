  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  # jump to 0x81FFFFFE : a 32-bit insn whose upper half is outside PMA_MEM_TOP
  li   t1, 0x81FFFFFE
  jalr x0, 0(t1)
  j    done
  .align 2
handler:
  csrr s0, mcause
  csrr s1, mepc
  csrr s2, mtval
done:
  li   t0, 0x80100000
  sw   s0, 0(t0)
  sw   s1, 4(t0)
  sw   s2, 8(t0)
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
