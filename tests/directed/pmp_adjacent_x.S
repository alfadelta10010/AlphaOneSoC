# Same for instruction fetch: lock a NAPOT entry (4 KiB, the grain; NA4 is not
# selectable) with R+W but no X over the
# instruction right after `csrw pmpcfg0`; fetching it must fault (cause 1).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  csrw pmpcfg0, zero          # Spike resets pmpcfg0 to NAPOT RWX, the core to OFF: start both from OFF (a pmpaddr write is logged as read back)
  la   t0, handler
  csrw mtvec, t0
  la   t1, victim
  srli t1, t1, 2
  ori  t1, t1, 0x1ff
  csrw pmpaddr0, t1          # NAPOT 4 KiB (the grain) over the page of `victim`
  li   t2, 0x9b              # L=1, A=NAPOT, R=1 W=1 X=0
  li   a1, 0
  la   t3, pre
  jr   t3
  # `victim` has to start a 4 KiB page, with the pmpcfg0 write the last
  # instruction of the page before it.
  .section .text.pg,"ax",@progbits
  .balign 4096
  .skip 4092
pre:
  csrw pmpcfg0, t2
victim:
  li   a1, 0xbad             # adjacent: fetch must fault
  nop
  .section .text.init
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
