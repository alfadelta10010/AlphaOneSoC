# minstret and minstreth written and read back under memory waits and
# through the SoC. cnt_xhalf checks the same rules (an explicit write
# replaces the increment; the other half reads what the write left) but
# only at zero wait and only at core level, because its mcycle cases count
# clocks; minstret counts retires, so this one is compared with Spike
# under every timing, the SoC's included:
#   * a low-half write at the carry edge, then a read-modify-write of the
#     high half, then both halves and their aliases;
#   * a high-half write straight before an alias read and a CSRRC;
#   * a low-half write followed by a load-use stall, then a read;
#   * a write straight before an ECALL, read in the handler and after.
# From the PR #5 review's probe (core slice, v2).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  # lo write at the carry edge, then RMW of the other half, then alias reads
  li   t1, -1
  li   t2, 0
  csrw minstret, t1
  csrrs t3, minstreth, t2      # RMW write of hi, reads hi with no carry
  csrr t4, minstret            # lo still 0xffffffff (csrrs replaced its increment)
  csrr t5, minstret            # 0 after wrap? lo wrapped by t4's retire
  csrr t6, minstreth           # hi+1 from the carry
  rdinstret a0
  rdinstreth a1
  # hi write immediately followed by alias read of lo and a CSRRC on lo
  li   t1, 7
  csrw minstreth, t1
  rdinstret a2
  csrrc a3, minstret, t2
  rdinstreth a4
  # lo write followed by a load-use stall and a read
  la   s0, scratch
  li   t1, 0x100
  csrw minstret, t1
  lw   s1, 0(s0)
  add  s1, s1, s1
  csrr a5, minstret
  # write, then trap in the next instruction, then read in the handler
  la   t0, handler
  csrw mtvec, t0
  li   t1, 0x200
  csrw minstret, t1
  ecall
  csrr a7, minstret
  csrw minstreth, zero
  csrr s2, minstreth
  csrr s3, minstret
  j    done
  .align 2
handler:
  csrr a6, minstret
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
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
scratch: .word 5
