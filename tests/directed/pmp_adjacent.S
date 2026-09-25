# A PMP CSR write must govern the very next instruction. Lock an NA4 entry
# with no permissions over a data word, then load it immediately: the load
# must fault (cause 5) even in M-mode, because the entry is locked.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x81000000
  li   t0, 0x1234
  sw   t0, 0(s0)
  li   t1, 0x20400000        # pmpaddr0 = 0x81000000 >> 2
  csrw pmpaddr0, t1
  li   t2, 0x90              # L=1, A=NA4, RWX=000
  li   a0, 0
  csrw pmpcfg0, t2
  lw   a0, 0(s0)             # adjacent: must fault
  li   a1, 0xbad
  .balign 4
handler:
  csrr a2, mcause
  csrr a3, mtval
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
