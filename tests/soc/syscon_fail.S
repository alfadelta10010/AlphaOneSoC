# A fail status halts the SoC like power-off: EPILOGUE's fail path with
# a6 = 0x5A (the code) and a7 = 0x1234 (the value seen). The bench expects
# FINISH (0x5A << 16) | 0x3333, VALUE2 = 0x1234, and then the power-off hold:
# the SoC in reset for 200 clocks with the pins at their reset values.
#
# Failure codes: 0x1nn (before the deliberate fail).
#include "periph.h"

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    lw   t0, 4(s11)
    CHECK t0, 0x1, 0x101             # RESET_CAUSE: PIN
    lw   t0, 0x0C(s11)
    CHECK t0, 0x41315301, 0x102      # CHIP_ID
    lw   t0, 0x100(s11)
    CHECK t0, 0, 0x103               # watchdog off
    li   a6, 0x5A
    li   a7, 0x1234
    j    test_fail

    EPILOGUE
