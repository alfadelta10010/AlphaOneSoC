/* Reset vector of the flash loader. The SoC boots here (0x2000_0000) and
 * nothing is initialised: registers x1-x31 have no reset, mtvec is 0. This
 * is boot contract rule 1 (mtvec before anything can trap); the rest is in
 * loader.c. */
    .section .text.init
    .globl _start
_start:
    .irp    r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\r, 0
    .endr
    la      t0, trap_entry
    csrw    mtvec, t0
    la      sp, _stack_top
    j       loader_main
