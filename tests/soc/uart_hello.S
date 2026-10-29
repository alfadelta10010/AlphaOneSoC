# Hello, world, twice, from flash, at the UART's reset divisor (the program
# never programs it).
#
#  1. Back-pressure alone: one store per character, no LSR polling. Each
#     store to THR waits while the previous character is on the line.
#  2. The polled way: wait for LSR.THRE before each store; no store waits.
#
# The testbench checks the RP2350 received both copies intact, that stores
# waited in part 1 (cue 1 to cue 2) and none in part 2 (cue 2 to cue 3).
#include "periph.h"
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, UART
    EVENT 1
    la   a0, hello
1:  lbu  t0, 0(a0)
    beqz t0, 2f
    sb   t0, THR(s0)
    addi a0, a0, 1
    j    1b
2:  EVENT 2
    la   a0, hello
3:  lbu  t0, 0(a0)
    beqz t0, 5f
    WAIT_LSR s0, LSR_THRE
    sb   t0, THR(s0)
    addi a0, a0, 1
    j    3b
5:  WAIT_LSR s0, LSR_TEMT
    EVENT 3
    lbu  t0, LSR(s0)
    CHECK t0, 0x60, 0x10
    j    test_pass
    EPILOGUE

    .section .rodata
hello: .asciz "Hello, world!\r\n"
