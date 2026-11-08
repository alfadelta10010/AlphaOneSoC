# QSPI_CFG (syscon +0x1C) and the no-stream strap, from flash. Two boots.
# The bench holds ui_in[2] (the no-stream strap) at its run value through the
# pin reset (+NO_STREAM: 1) and moves it to the opposite on EVENT 0x65, before
# the reboot.
#
#   boot 1  cause 0x1: QSPI_CFG reads 0x1 (strap 0) or 0x0 (strap 1) -- VALUE;
#           STRAPS -- VALUE (bit 1 is the strap, the bench compares);
#           STREAM cleared, 64 four-byte nops run from flash (EVENT 0x61 / 0x62:
#           the bench counts the flash read commands in between -- one per
#           fetch); STREAM set, 64 nops again (EVENT 0x63 / 0x64: the commands
#           of a sequential run share one); DDR and DDR_CAP written and read
#           back; QSPI_CFG left at 0x1E (STREAM off, DDR on) and a reboot
#   boot 2  cause 0x3: QSPI_CFG is back at the strap's value although the pin
#           has moved (not re-read), DDR 0; STRAPS unchanged -- VALUE x2
#
# Failure codes: 0x1nn boot 1, 0x2nn boot 2.
#include "periph.h"

.macro NOPS64
    .option push
    .option norvc
    .rept 64
    nop
    .endr
    .option pop
.endm

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    lw   s0, 4(s11)                  # RESET_CAUSE
    andi t0, s0, 2
    bnez t0, boot2
    CHECK s0, 0x1, 0x101
    lw   t0, 0x1C(s11)               # QSPI_CFG at reset
    VALUE t0
    andi t1, t0, -2
    CHECK t1, 0, 0x102               # DDR and DDR_CAP reset to 0
    lw   t0, 0x10(s11)               # STRAPS
    VALUE t0
    sw   zero, 0x1C(s11)             # STREAM off, running from flash
    lw   t0, 0x1C(s11)
    CHECK t0, 0, 0x103
    EVENT 0x61
    NOPS64
    EVENT 0x62
    li   t1, 1
    sw   t1, 0x1C(s11)               # STREAM on again
    lw   t0, 0x1C(s11)
    CHECK t0, 1, 0x104
    EVENT 0x63
    NOPS64
    EVENT 0x64
    li   t1, 0x1F
    sw   t1, 0x1C(s11)
    lw   t0, 0x1C(s11)
    CHECK t0, 0x1F, 0x105            # all fields stored
    li   t1, 0xFFFFFFE0
    sw   t1, 0x1C(s11)
    lw   t0, 0x1C(s11)
    CHECK t0, 0, 0x106               # bits [31:5] are not storage
    li   t1, 0x1E
    sw   t1, 0x1C(s11)               # STREAM off, DDR on, CAP 7
    EVENT_P 0x65
    li   t1, 0x7777
    sw   t1, 0(s11)                  # reboot
1:  j    1b

boot2:
    CHECK s0, 0x3, 0x201
    lw   t0, 0x1C(s11)
    VALUE t0
    lw   t0, 0x10(s11)
    VALUE t0
    j    test_pass

    EPILOGUE
