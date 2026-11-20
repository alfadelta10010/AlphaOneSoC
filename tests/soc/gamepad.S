# Gamepad receiver on the bus (GPIO window +0x10 / +0x14) and its change interrupt through the PLIC
# (source 3). Needs the bench's gamepad model (+GAMEPAD=1) running a scripted sequence; each EVENT n
# tells the bench to switch to step n and the program waits for the interrupt that the new frame raises.
#   start  before any frame: GAMEPAD reads 0 (no pad present), GPSTAT 0, no interrupt
#   step 1 pad 0 present, buttons 0x123; pad 1 absent        -> GAMEPAD 0x00008123 (pr0 is bit 15)
#   step 2 pad 0 0x123 and pad 1 0x456 present                -> GAMEPAD 0x84568123
#   step 3 pad 0 absent, pad 1 0x456                          -> GAMEPAD 0x84560000
#   step 4 both absent                                        -> GAMEPAD 0
# Per step: MEIP rises, claim = 3, GPSTAT.chg = 1 and ie = 1, GAMEPAD as listed, W1C of chg drops MEIP
# and a second claim is 0 after complete. Then: ie = 0 masks the interrupt of a changed frame (chg 1,
# MEIP 0), W1C of chg clears it. The same frame repeated raises nothing.
#include "periph4.h"
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, GPIO
    PLIC_SETUP (1 << SRC_PAD)
    lw   t0, G_PAD(s0)
    CHECK t0, 0, 0x01
    lw   t0, G_PADSTAT(s0)
    CHECK t0, 0, 0x02
    li   t0, 2
    sw   t0, G_PADSTAT(s0)        # ie = 1 (wdata[0] = 0: chg untouched)
    lw   t0, G_PADSTAT(s0)
    CHECK t0, 2, 0x03
    NO_MEIP 0x04

    EVENT_P 1
    WAIT_MEIP 0x10
    CLAIM SRC_PAD, 0x11
    lw   t1, G_PAD(s0)
    li   t2, 0x00008123
    CHECKR t1, t2, 0x12
    lw   t1, G_PADSTAT(s0)
    CHECK t1, 3, 0x13
    li   t1, 3
    sw   t1, G_PADSTAT(s0)        # W1C chg, keep ie
    COMPLETE
    lw   t1, G_PADSTAT(s0)
    CHECK t1, 2, 0x14
    NO_MEIP 0x15
    lw   t0, 4(a4)
    CHECK t0, 0, 0x16

    EVENT_P 2
    WAIT_MEIP 0x20
    CLAIM SRC_PAD, 0x21
    lw   t1, G_PAD(s0)
    li   t2, 0x84568123
    CHECKR t1, t2, 0x22
    li   t1, 3
    sw   t1, G_PADSTAT(s0)
    COMPLETE

    EVENT_P 3
    WAIT_MEIP 0x30
    CLAIM SRC_PAD, 0x31
    lw   t1, G_PAD(s0)
    li   t2, 0x84560000
    CHECKR t1, t2, 0x32
    li   t1, 3
    sw   t1, G_PADSTAT(s0)
    COMPLETE

    # step 4 with ie off: chg rises, no interrupt
    sw   zero, G_PADSTAT(s0)
    EVENT_P 4
    DELAY 400000                  # a few frames
    lw   t1, G_PADSTAT(s0)
    CHECK t1, 1, 0x40             # chg, ie 0
    NO_MEIP 0x41
    lw   t1, G_PAD(s0)
    CHECK t1, 0, 0x42
    li   t1, 1
    sw   t1, G_PADSTAT(s0)        # W1C, ie stays 0
    lw   t1, G_PADSTAT(s0)
    CHECK t1, 0, 0x43
    # the same frame again: no change
    DELAY 400000
    lw   t1, G_PADSTAT(s0)
    CHECK t1, 0, 0x44
    j    test_pass
    EPILOGUE
