# A pmpaddr write refetches the next instruction, so its fetch is checked
# against the new value (CPU ref 2.1, 2.3; Priv 3.7.1). pmp_refetch only moved
# pmpcfg0; FC32 drops the refetch for pmpaddr writes alone. Entry 0 is
# unlocked and sits in front of entry 1, which is locked and binds M-mode, so
# moving entry 0 changes which entry matches an M-mode fetch first.
#   1. grant -> deny: pmpaddr0 is moved away from target1 by the write right
#      before it; target1 must fault (cause 1, mtval = target1).
#   2. deny -> grant: pmpaddr0 is moved onto target2 (entry 2 over it has no
#      X), right before it; target2 must execute.
# Spike checks every fetch against the current PMP, so it is the reference.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   t6, handler
  csrw mtvec, t6
  li   s0, 0
  li   s1, 0
  li   a1, 0
  li   a5, 0
  # part 1: grant -> deny
  la   t0, target1
  srli t0, t0, 2
  csrw pmpaddr0, t0
  csrw pmpaddr1, t0
  li   t0, 0x9117              # e0 NA4 RWX unlocked, e1 NA4 L|R
  csrw pmpcfg0, t0
  nop
  li   t0, 0x203C0000
  csrw pmpaddr0, t0            # e0 moves to 0x80F00000
target1:
  addi a1, a1, 1               # must fault
  # part 2: deny -> grant
  la   t0, target2
  srli t0, t0, 2
  csrw pmpaddr2, t0
  li   t0, 0x919117            # e2 NA4 L|R (no X); e1 locked, unchanged
  csrw pmpcfg0, t0
  nop
  la   t0, target2
  srli t0, t0, 2
  csrw pmpaddr0, t0            # e0 (unlocked) now covers target2
target2:
  addi a5, a5, 1               # must execute
  mv   a3, s0
  mv   a4, s1
  li   t4, 1
  la   t5, tohost
  sw   t4, 0(t5)
1: j 1b

  .balign 4
handler:
  addi s0, s0, 1
  csrr s1, mtval
  csrr t5, mepc
  addi t5, t5, 4
  csrw mepc, t5
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
