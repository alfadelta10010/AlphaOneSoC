# A pmpaddr write refetches the next instruction, so its fetch is checked
# against the new value (CPU ref 2.1, 2.3; Priv 3.7.1). pmp_refetch only moved
# pmpcfg0; FC32 drops the refetch for pmpaddr writes alone. Entry 0 is
# unlocked and sits in front of entry 1, which is locked and binds M-mode, so
# moving entry 0 changes which entry matches an M-mode fetch first.
#   (NA4 is not selectable at the 4 KiB grain; the entries are NAPOT pages.)
#   1. grant -> deny: pmpaddr0 is moved away from target1 by the write right
#      before it; target1 must fault (cause 1, mtval = target1).
#   2. deny -> grant: pmpaddr0 is moved onto target2 (entry 2 over it has no
#      X), right before it; target2 must execute.
# Spike checks every fetch against the current PMP, so it is the reference.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  csrw pmpcfg0, zero          # Spike resets pmpcfg0 to NAPOT RWX, the core to OFF: start both from OFF (a pmpaddr write is logged as read back)
  la   t6, handler
  csrw mtvec, t6
  li   s0, 0
  li   s1, 0
  li   a1, 0
  li   a5, 0
  # part 1: grant -> deny
  la   t0, target1
  srli t0, t0, 2
  ori  t0, t0, 0x1ff           # NAPOT 4 KiB over the page of target1 (the grain)
  csrw pmpaddr0, t0
  csrw pmpaddr1, t0
  li   t0, 0x991f              # e0 NAPOT RWX unlocked, e1 NAPOT L|R
  csrw pmpcfg0, t0
  nop
  li   t0, 0x203C01ff
  la   t6, pre1
  jr   t6
  # Each target has to start a 4 KiB page, with the pmpaddr0 write the last
  # instruction of the page before it.
  .section .text.pg,"ax",@progbits
  .balign 4096
  .skip 4092
pre1:
  csrw pmpaddr0, t0            # e0 moves to 0x80F00000
target1:
  addi a1, a1, 1               # must fault
  .skip 4092
cont1:
  # part 2: deny -> grant
  la   t0, target2
  srli t0, t0, 2
  ori  t0, t0, 0x1ff
  csrw pmpaddr2, t0
  li   t0, 0x99991f            # e2 NAPOT L|R (no X); e1 locked, unchanged
  csrw pmpcfg0, t0
  nop
  la   t0, target2
  srli t0, t0, 2
  ori  t0, t0, 0x1ff
  la   t6, pre2
  jr   t6
  .balign 4096
  .skip 4092
pre2:
  csrw pmpaddr0, t0            # e0 (unlocked) now covers target2
target2:
  addi a5, a5, 1               # must execute
  mv   a3, s0
  mv   a4, s1
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .section .text.init
  .balign 4
handler:
  addi s0, s0, 1
  csrr s1, mtval
  la   t5, cont1
  csrw mepc, t5
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
