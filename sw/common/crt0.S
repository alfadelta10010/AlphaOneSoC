/* Start-up for a program the loader has copied to PSRAM and jumped to.
 * Registers are not zero (the loader used them), mtvec still points at the
 * loader's handler, and .bss has not been cleared. */
    .section .text.init
    .globl _start
_start:
    la      sp, _stack_top
    la      t0, trap_entry
    csrw    mtvec, t0
    la      t0, _bss_start
    la      t1, _bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:  li      a0, 0
    li      a1, 0
    call    main
    call    exit
3:  j       3b
