# `csrs mie` enabling a pending interrupt: it must be taken right after the
# write (Priv 3.1.9), not one instruction later.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   s2, 0                  # counted up below (x-regs are not reset)
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x02000000
  li   t2, 8
  li   t3, 1
  csrsi mstatus, 8            # MIE=1
  sw   t3, 0(s0)              # msip=1, mie.MSIE still 0 -> not taken
  nop
  nop
  csrs mie, t2                # enable: must be taken immediately after this
  addi s2, s2, 1
  addi s2, s2, 1
  addi s2, s2, 1
  li   a4, 0x999
  j    done
  .align 2
handler:
  csrr a4, mepc
  csrr a5, mie
  mv   a6, s2
done:
  sw   x0, 0(s0)
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
