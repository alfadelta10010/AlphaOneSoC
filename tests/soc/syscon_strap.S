# The read-sampling strap is latched at the pin reset and not re-read at a
# reboot. Two boots. The bench holds the strap pin at its reset value through
# boot 1 (a run with +RD_LATE has it at 1 through the pin reset and 0 from the
# first edge after), and on EVENT 0x52 moves it to the opposite of the latched
# value and keeps it there through the reboot.
#
#   boot 1  cause 0x1: report STRAPS (VALUE; the bench compares it with the pin
#           it drove at the reset), keep it in BOOT_MODE, cue 0x52, reboot
#   boot 2  cause 0x3: STRAPS still reads what boot 1 saw, and the program got
#           here at all: in the +RD_LATE run with the Pmod model's 25 ns device
#           delay, a flash fetch works only while the engine still samples
#           late, i.e. from the latched value and not the pin (now 0)
#
# Failure codes: 0x1nn boot 1, 0x2nn boot 2.
#include "periph.h"

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    lw   s0, 4(s11)                  # RESET_CAUSE
    andi t0, s0, 2
    bnez t0, boot2
    CHECK s0, 0x1, 0x101
    lw   t0, 0x10(s11)               # STRAPS
    andi t1, t0, -2
    CHECK t1, 0, 0x102               # only bit 0
    VALUE t0
    addi t1, t0, 0x40
    sw   t1, 8(s11)                  # BOOT_MODE = 0x40 | strap
    EVENT_P 0x52
    li   t1, 0x7777
    sw   t1, 0(s11)                  # reboot
1:  j    1b

boot2:
    CHECK s0, 0x3, 0x201
    lw   t1, 8(s11)
    andi t2, t1, -2
    CHECK t2, 0x40, 0x202            # BOOT_MODE survived
    andi t1, t1, 1
    lw   t0, 0x10(s11)
    CHECKR t0, t1, 0x203             # STRAPS equals boot 1's
    j    test_pass

    EPILOGUE
