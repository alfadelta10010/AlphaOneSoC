# After `csrc mie` disables a pending interrupt, it must not be taken. Spike
# takes it one instruction earlier, before the csrc, because its msip store is
# visible at once (MMIO latency is implementation-defined), so this checks
# the core's behaviour: the handler never runs.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s0, 0x02000000
  li   t2, 8
  li   t3, 1
  csrsi mstatus, 8            # MIE=1
  csrs mie, t2                # MSIE=1, nothing pending yet
  nop
  nop
  sw   t3, 0(s0)              # msip=1: pending from here on
  csrc mie, t2                # disable
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
