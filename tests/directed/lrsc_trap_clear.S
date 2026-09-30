# An interrupt taken between an LR and its SC clears the reservation, so
# the SC fails. Since same-hart stores keep the reservation, this is all
# that protects an LR/SC sequence from an interrupt handler's stores. The
# interrupt is put inside the pair by construction, so the test holds at
# any memory speed: after the LR the program makes the timer pending (a
# store to mtimecmp -- a same-hart store, which leaves the reservation
# alone), sets MIE and waits. A control runs the same sequence with MIE
# off first: there the SC succeeds, so the stores are not what fails it.
# DUT-only: the timer counts clocks here and instructions on Spike.
#
#   x12  control SC: 0 (succeeded)
#   x10  SC with the interrupt between: 1 (failed)
#   x19  interrupts taken: 1
#   x11  the word at the end: 0x77, the control SC's value
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t0, handler
  csrw mtvec, t0
  la   s0, wa
  li   s1, 0x02004000         # mtimecmp
  li   t0, -1
  sw   t0, 4(s1)              # far future
  li   t0, 0x80
  csrw mie, t0                # MTIE; mstatus.MIE still 0
  li   s3, 0
  li   t2, 0x77
  # control: the timer goes pending, but MIE stays 0
  lr.w t5, (s0)
  sw   zero, 0(s1)
  sw   zero, 4(s1)            # mtimecmp = 0: MTIP pending
  nop
  nop
  nop
  nop
  nop
  nop
  sc.w a2, t2, (s0)           # 0
  li   t0, -1
  sw   t0, 4(s1)              # far future again
  nop
  nop
  nop
  nop
  # the same with MIE set: the interrupt lands between the LR and the SC
  lr.w t5, (s0)
  sw   zero, 4(s1)            # pending
  csrsi mstatus, 8
  nop
  nop
  nop
  nop
  nop
  nop
  sc.w a0, t2, (s0)           # 1: the trap cleared the reservation
  csrci mstatus, 8
  lw   a1, 0(s0)
  j    done
  .align 2
handler:
  addi s3, s3, 1
  li   a3, -1
  li   a4, 0x02004000
  sw   a3, 4(a4)              # far future
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
  .data
  .align 4
wa: .word 0x11111111
