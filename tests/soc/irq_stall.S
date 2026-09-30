# Timer interrupts arriving while a store is held by a peripheral's
# back-pressure:
#
#  A. a THR write held while the previous character is on the line;
#  B. a SPI DATA write held while the previous byte shifts (DIV 3);
#  C. the write half of an amoswap.w to THR, held the same way, after its
#     read half popped a received byte from RBR.
#
# The core must not inject an interrupt while a data request waits (the
# testbench checks that on every clock). It takes it once the store has
# completed, with mepc = the next instruction, and the store is made once:
# the testbench counts THR loads and RBR pops, checks the characters and SPI
# bytes that came out, and for every interrupt that was pending while the
# store waited, checks the mepc the handler reports (VALUE) against the
# address the program gave it (VALUE2). Each part sweeps the timer delay so
# the interrupt lands before, in and after the stall; the testbench also
# requires that some did land in it.
#
# The handler uses a3 and a4 only; nothing else holds live values across
# the points the interrupt can land on.
#include "periph.h"
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    li   s0, UART
    li   s1, GPIO
    li   s3, MTIMECMP
    la   t0, handler
    csrw mtvec, t0
    li   t0, -1
    sw   t0, 0(s3)               # mtimecmp = 0x0000_0000_ffff_ffff: far off
    sw   zero, 4(s3)
    li   t0, 0x80
    csrw mie, t0                 # MTIE
    csrsi mstatus, 8             # MIE
    li   s5, 0                   # interrupts taken
    li   s8, 0                   # interrupts expected so far

    # ---- A: THR ----
    la   t0, a_after
    sw   t0, MB_VALUE2(s11)
    EVENT 1
    li   s6, 0                   # timer delay, clocks
    li   s7, 12
a_loop:
    WAIT_LSR s0, LSR_TEMT
    addi s8, s8, 1
    li   t6, MTIME
    lw   t0, 0(t6)
    add  t0, t0, s6
    sw   t0, 0(s3)               # mtimecmp = now + delay
    li   t1, 'A'
    li   t2, 'B'
    sb   t1, THR(s0)
    sb   t2, THR(s0)             # held while 'A' is on the line
a_after:
    nop
1:  blt  s5, s8, 1b              # the interrupt, sooner or later
    addi s6, s6, 100
    addi s7, s7, -1
    bnez s7, a_loop
    WAIT_LSR s0, LSR_TEMT

    # ---- B: SPI DATA ----
    li   t0, 0x07
    sw   t0, G_CTRL(s1)          # EN, DIV 3: 136 clocks a byte
    li   t0, 0x48
    sw   t0, G_OUT(s1)           # RES# high, CS# low: the OLED model listens
    la   t0, b_after
    sw   t0, MB_VALUE2(s11)
    EVENT 2
    li   s6, 0
    li   s7, 16
b_loop:
1:  lw   t0, G_CTRL(s1)
    andi t0, t0, 0x100
    bnez t0, 1b
    addi s8, s8, 1
    li   t6, MTIME
    lw   t0, 0(t6)
    add  t0, t0, s6
    sw   t0, 0(s3)
    li   t1, 0x55
    li   t2, 0xAA
    sw   t1, G_DATA(s1)
    sw   t2, G_DATA(s1)          # held while 0x55 shifts
b_after:
    nop
1:  blt  s5, s8, 1b
    addi s6, s6, 25
    addi s7, s7, -1
    bnez s7, b_loop
1:  lw   t0, G_CTRL(s1)
    andi t0, t0, 0x100
    bnez t0, 1b
    li   t0, 0x49
    sw   t0, G_OUT(s1)           # CS# high

    # ---- C: amoswap.w to THR ----
    la   t0, c_after
    sw   t0, MB_VALUE2(s11)
    EVENT 3
    li   s6, 100
    li   s7, 9
    li   s9, 'a'                 # the byte the RP2350 sends next
c_loop:
    WAIT_LSR s0, LSR_TEMT
    EVENT 4                      # the RP2350 sends s9
    WAIT_LSR s0, LSR_DR
    addi s8, s8, 1
    li   t6, MTIME
    lw   t0, 0(t6)
    add  t0, t0, s6
    sw   t0, 0(s3)
    li   t1, 'P'
    sb   t1, THR(s0)
    EVENT 5                      # the testbench counts pops and THR loads from here
    li   t0, 0x5A
    amoswap.w t3, t0, (s0)       # read pops RBR; write (THR = 0x5A) held while 'P' goes
c_after:
    EVENT 6                      # ... to here: one of each
    andi t3, t3, 0xFF
    CHECKR t3, s9, 0x301
    lbu  t0, LSR(s0)
    andi t0, t0, LSR_DR
    CHECK t0, 0, 0x302
1:  blt  s5, s8, 1b
    addi s9, s9, 1
    addi s6, s6, 100
    addi s7, s7, -1
    bnez s7, c_loop
    WAIT_LSR s0, LSR_TEMT
    csrci mstatus, 8
    j    test_pass

    .align 2
handler:
    csrr a3, mcause
    li   a4, 0x80000007
    bne  a3, a4, 1f
    csrr a3, mepc
    sw   a3, MB_VALUE(s11)       # checked by the testbench
    li   a4, -1
    sw   a4, 0(s3)               # mtimecmp far off again: MTIP drops
    addi s5, s5, 1
    mret
1:  mv   a7, a3
    li   a6, 0x3FF               # not a timer interrupt
    j    test_fail
    EPILOGUE
