# Jump to an unmapped alias (0x82000000 + off) of a MUL. DUT memory aliases
# addr[24:0], so the fetched word is the MUL; PMA must fault it (cause 1).
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  la   t1, target
  li   t2, 0x02000000
  add  t1, t1, t2          # 0x82xxxxxx -> outside PMA_MEM window
  jr   t1
  .align 4
target:
  mul  a2, a0, a1
  nop
  nop
  .align 4
handler:
  csrr a3, mcause
  csrr a4, mtval
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
