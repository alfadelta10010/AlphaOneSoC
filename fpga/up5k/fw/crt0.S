    .section .text.start
    .globl _start
_start:
    la   sp, _stack_top
    la   t0, _bss
    la   t1, _ebss
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:  la   t0, _ramcode_lma      /* .ramcode: flash -> PSRAM */
    la   t1, _ramcode
    la   t2, _eramcode
4:  bgeu t1, t2, 5f
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j    4b
5:  call main
3:  j    3b
