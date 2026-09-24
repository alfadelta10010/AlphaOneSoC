# Same for instruction fetch: lock an NA4 entry with R+W but no X over the
# instruction right after `csrw pmpcfg0`; fetching it must fault (cause 1).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  la   t1, victim
  srli t1, t1, 2
  csrw pmpaddr0, t1          # NA4 over `victim`
  li   t2, 0x93              # L=1, A=NA4, R=1 W=1 X=0
  li   a1, 0
  .balign 4
  csrw pmpcfg0, t2
victim:
  li   a1, 0xbad             # adjacent: fetch must fault
  nop
  .balign 4
handler:
  csrr a2, mcause
  csrr a3, mtval
  csrr a4, mepc
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
