# The CLINT registers MTIP (src/clint.v), so it lags a change of mtimecmp:
# after a store moves mtimecmp into the future, mip.MTIP still reads 1 for
# two clocks -- one for the store to commit in WB, one for the register.
# The next instruction reads mip in its third EX cycle at the earliest, so
# with a fast memory it no longer sees the stale bit; it does when the store
# waits for its memory, having done its EX cycles meanwhile. An interrupt enabled
# in that window would be taken although nothing is pending by the time the
# handler reads mip. Priv 3.2.1 allows it ("... reflected in MTIP
# eventually, but not necessarily immediately. A spurious timer interrupt
# might occur"). A csrsi of MIE straight after the store does not reach it:
# the instruction behind a CSR write waits a clock in EX for the write to
# commit, and MTIP has cleared by then. Linux never comes close either:
# clint_clock_next_event runs with MIE = 0, several instructions before
# interrupts come back on, and MRET always leaves a bubble. Spike updates
# MTIP at once, so this is DUT-only; it pins the window at both ends so
# that a change to it shows.
#
#   x19  mip with mtimecmp = 0: 0x80
#   x22  mip on the instruction after the store to mtimecmp_hi: 0 (the
#        window has closed), or 0x80 behind a store that waited
#   x23  mip on the one after that: 0
#   x24  mip on the third: 0
#   x20  mip two instructions after MIE is set: 0
#   x18  timer interrupts taken after MIE was set (spurious ones): 0
#   x12  mip as the handler read it: 0 if it was spurious (-1 if none)
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  li   s2, 0
  li   a2, -1
  li   s0, 0x02004000
  li   t0, 0x80
  csrw mie, t0                # MTIE; mstatus.MIE stays 0 for now
  # (a) mip right after mtimecmp moves away
  sw   zero, 0(s0)
  sw   zero, 4(s0)            # mtimecmp = 0: MTIP pending
  nop
  nop
  nop
  nop
  csrr s3, mip                # 0x80
  li   t1, -1
  sw   t1, 4(s0)              # mtimecmp = far future
  csrr s6, mip
  csrr s7, mip
  csrr s8, mip
  # (b) MIE set on the instruction right after the store
  sw   zero, 4(s0)            # pending again
  nop
  nop
  nop
  nop
  sw   t1, 4(s0)              # far future
  csrsi mstatus, 8            # MIE = 1 right after
  nop
  nop
  csrr s4, mip                # 0
  csrci mstatus, 8
  j    done
  .align 2
handler:
  addi s2, s2, 1
  csrr a0, mcause
  csrr a2, mip                # what was pending when we got here
  csrr a3, mepc
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
