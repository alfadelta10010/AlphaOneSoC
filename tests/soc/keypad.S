# The PmodKYPD scanned in software, as docs/pins-and-peripherals.md
# describes: drive one column low and the others high, read the rows (low =
# pressed), four times over. Columns COL1..COL4 are out[3..0], rows
# ROW1..ROW4 are in[7..4].
#
# For each key pattern the testbench presses (cue 1), the program scans and
# reports a 16-bit mask, bit 4 x row + column (ROW1/COL1 = 0), as VALUE; the
# testbench checks it. The SPI transmitter stays off (EN = 0), so out[1]
# and out[3] are plain GPIO.
#
# After driving a column the program reads IN twice and discards both
# reads before the one it uses. The column pin changes on the edge the OUT
# store completes, and IN is two synchroniser flops behind the pins, so a
# load must complete at least three clocks after the store to see the new
# rows. Back-to-back loads complete a clock apart when memory is fast: the
# first two would read the old rows (measured with a zero-wait bench by
# the PR #5 review). At QSPI speed one discard would do, but a driver
# written from this must not depend on the memory being slow.
#include "periph.h"
#define NSETS 28
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s1, GPIO
    sw   zero, G_CTRL(s1)        # EN = 0: the keypad owns out[3:0]
    li   s2, NSETS
1:  EVENT_P 1
    jal  scan
    VALUE a0
    addi s2, s2, -1
    bnez s2, 1b
    li   t0, 0x0F
    sw   t0, G_OUT(s1)           # all columns high
    j    test_pass

scan:
    li   a0, 0
    li   t0, 0                   # column c
1:  li   t1, 8
    srl  t1, t1, t0              # COLc is out[3 - c]
    xori t1, t1, 0x0F            # that column low, the others high
    sw   t1, G_OUT(s1)
    lw   t2, G_IN(s1)            # settle: discarded
    lw   t2, G_IN(s1)            # settle: discarded
    lw   t2, G_IN(s1)
    srli t2, t2, 4
    xori t2, t2, 0x0F            # t2[3] = ROW1 pressed ... t2[0] = ROW4
    li   t3, 0                   # row r
2:  li   t4, 3
    sub  t4, t4, t3
    srl  t5, t2, t4
    andi t5, t5, 1
    beqz t5, 3f
    slli t6, t3, 2
    add  t6, t6, t0
    li   t5, 1
    sll  t5, t5, t6
    or   a0, a0, t5
3:  addi t3, t3, 1
    li   t4, 4
    blt  t3, t4, 2b
    addi t0, t0, 1
    blt  t0, t4, 1b
    ret
    EPILOGUE
