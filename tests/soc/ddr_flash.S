# DDR (EDh) flash reads, from flash. QSPI_CFG.DDR switches the flash reads of both
# the instruction fetch and the loads, so this program runs its own code from flash
# in SDR, computes three checksums, sets DDR_CAP and DDR, computes them again, and
# compares:
#   sum    32 words of a table in flash (loads: streamed continuations)
#   block  a straight-line block of mixed 16- and 32-bit instructions (fetch stream,
#          halfword top-ups, opens at addr[1] = 1)
#   loop   a loop of the same, branching back (stream closes, new opens)
# then DDR off (SDR again, the stream is closed by the mode change), the checksums,
# DDR on again, the checksums, and the same QSPI_CFG stored once more.
#
# The capture point under test is -DDDR_PT=<n> (default 0): the bench's device and
# clock must read it (the Makefile's ddr_flash@<n> runs choose the model delays).
# Failure codes: 0x1nn the SDR reference differs from itself, 0x2nn DDR, 0x3nn DDR off
# again, 0x4nn DDR on again, 0x5nn after the store of the same value.
#include "periph.h"

#ifndef DDR_PT
#define DDR_PT 0
#endif
#define CFG_SDR   0x1                       /* STREAM on, DDR off */
#define CFG_DDR   (1 | 2 | (DDR_PT << 2))   /* STREAM on, DDR on, CAP = DDR_PT */

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    lw   t0, 0x1C(s11)               # QSPI_CFG at reset: STREAM on, DDR off, DDR_CAP 2
    CHECK t0, 0x9, 0x001
    li   t0, CFG_SDR
    sw   t0, 0x1C(s11)
    jal  ra, run_all                 # the SDR reference
    mv   s0, a0
    mv   s1, a1
    mv   s2, a2
    jal  ra, run_all                 # and again, to be sure it repeats
    CHECKR a0, s0, 0x101
    CHECKR a1, s1, 0x102
    CHECKR a2, s2, 0x103

    li   t0, CFG_DDR
    sw   t0, 0x1C(s11)
    jal  ra, run_all
    CHECKR a0, s0, 0x201
    CHECKR a1, s1, 0x202
    CHECKR a2, s2, 0x203

    li   t0, CFG_SDR
    sw   t0, 0x1C(s11)
    jal  ra, run_all
    CHECKR a0, s0, 0x301
    CHECKR a1, s1, 0x302
    CHECKR a2, s2, 0x303

    li   t0, CFG_DDR
    sw   t0, 0x1C(s11)
    jal  ra, run_all
    CHECKR a0, s0, 0x401
    CHECKR a1, s1, 0x402
    CHECKR a2, s2, 0x403

    # The same value stored again with DDR on, a stream open: nothing changes, so
    # the stream must go on (no close, no wrong word).
    li   t0, CFG_DDR
    sw   t0, 0x1C(s11)
    jal  ra, run_all
    CHECKR a0, s0, 0x501
    CHECKR a1, s1, 0x502
    CHECKR a2, s2, 0x503
    j    test_pass

# a0 = table sum, a1 = block, a2 = loop
run_all:
    mv   s3, ra
    jal  ra, fsum
    mv   s4, a0
    jal  ra, fblock
    mv   s5, a0
    jal  ra, floop
    mv   a2, a0
    mv   a0, s4
    mv   a1, s5
    jr   s3

fsum:
    la   t0, table
    li   t1, 32
    li   a0, 0
1:  lw   t2, 0(t0)
    add  a0, a0, t2
    slli a0, a0, 1
    srli t3, a0, 31
    or   a0, a0, t3
    addi t0, t0, 4
    addi t1, t1, -1
    bnez t1, 1b
    ret

# 96 mixed instructions in a row: compressible and not
fblock:
    li   a0, 0x1234
    li   t1, 1
    .rept 12
    addi a0, a0, 3
    xori a0, a0, 0x55
    add  a0, a0, a0
    slli a0, a0, 1
    srli a0, a0, 1
    andi a0, a0, 0x7ff
    ori  a0, a0, 0x21
    xor  a0, a0, t1
    addi t1, t1, 1
    addi a0, a0, 5
    .endr
    ret

floop:
    li   a0, 1
    li   t1, 40
1:  slli t2, a0, 3
    xor  a0, a0, t2
    srli t2, a0, 5
    xor  a0, a0, t2
    addi a0, a0, 7
    addi t1, t1, -1
    bnez t1, 1b
    ret

    .section .rodata
    .align 2
table:
    .set tv, 0x13579bdf
    .rept 32
    .word tv
    .set tv, (tv * 5 + 0x3779) & 0xffffffff
    .endr

    .text
    EPILOGUE
