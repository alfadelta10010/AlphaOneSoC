/* mtvec target. A trap can come from anywhere, including a corrupt stack,
 * so start from the top of PSRAM again. */
    .section .text
    .align 2
    .globl trap_entry
trap_entry:
    la      sp, _stack_top
    call    trap_report
1:  j       1b
