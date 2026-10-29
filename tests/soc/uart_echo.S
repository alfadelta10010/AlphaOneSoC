# Echo, with RTS# flow control. The testbench's RP2350 model sends a line
# with CTS flow control on (cue 1); the program echoes each character as it
# arrives -- poll LSR.DR, pop RBR, store to THR -- and checks it against its
# own copy of the line. The model can only send while RTS# is asserted, so
# nothing is lost and OE never rises, however slowly the program runs.
#
# Then an overrun on purpose (cue 2): the model sends "XYZ" back to back
# with flow control off while the program keeps its hands off the UART. X
# is kept, Y and Z are dropped: LSR = DR | OE | THRE | TEMT, RBR = X, and
# the LSR read clears OE.
#include "periph.h"
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, UART
    la   a0, line
    EVENT_P 1
1:  lbu  t0, 0(a0)
    beqz t0, 3f
2:  lbu  t1, LSR(s0)
    andi t2, t1, LSR_OE
    beqz t2, 4f
    mv   a7, t1
    li   a6, 0x11                # OE with flow control on
    j    test_fail
4:  andi t2, t1, LSR_DR
    beqz t2, 2b
    lbu  t1, RBR(s0)
    CHECKR t1, t0, 0x12
    sb   t1, THR(s0)             # waits while the previous echo is on the line
    addi a0, a0, 1
    j    1b
3:  WAIT_LSR s0, LSR_TEMT
    lbu  t1, LSR(s0)
    CHECK t1, 0x60, 0x13

    EVENT_P 2                      # "XYZ", flow control off
    DELAY 3000                   # three frames at divisor 4 are 1920 clocks
    lbu  t1, LSR(s0)
    CHECK t1, 0x63, 0x20
    lbu  t1, RBR(s0)
    CHECK t1, 'X', 0x21
    lbu  t1, LSR(s0)
    CHECK t1, 0x60, 0x22
    EVENT_P 3
    j    test_pass
    EPILOGUE

    .section .rodata
line: .asciz "The quick brown fox jumps over the lazy dog, 0123456789!\r\n"
