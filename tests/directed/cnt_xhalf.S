# A write to one half of mcycle/minstret is done instead of that
# instruction's increment (Zicsr), so the instruction right behind it must
# read the *other* half unchanged. csr_fwd forwards only the written half,
# so this is the read port's own value, back to back with the write in WB.
# Before 97105f2/4c8ce94 the read port kept the increment the write had
# discarded (case 1 read 0x102, case 2 read minstreth 1 then 0).
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  # 1: minstreth write, then adjacent minstret read (low half, no carry)
  li   t1, 0x100
  csrw minstret, t1
  li   t2, 0x5
  csrw minstreth, t2
  csrr a0, minstret        # 0x101: only the li after the first write counts
  # 2: minstret write with old lo = ffffffff, adjacent minstreth read
  li   t1, -1
  li   t2, 0x7
  csrw minstreth, x0
  csrw minstret, t1
  csrw minstret, t2        # old lo = ffffffff: must NOT carry into hi
  csrr a1, minstreth       # 0
  csrr a2, minstreth       # 0
  # 3: an mcycleh write with an adjacent mcycle read is cnt_xcycle.S: what
  # it reads counts clocks, so it cannot be compared with Spike line by line
  # 4: mcycle write with old lo = ffffffff, adjacent mcycleh read
  li   t1, -1
  li   t2, 0x7
  csrw mcycleh, x0
  csrw mcycle, t1
  csrw mcycle, t2
  csrr a4, mcycleh         # 0
  csrr a5, mcycleh
  # 5: rv32mi-instret_overflow test 3
  li   t1, -1
  csrw minstret, t1
  csrw minstreth, t1
  nop
  csrr a6, minstret        # 0
  csrr a7, minstreth       # 0
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
