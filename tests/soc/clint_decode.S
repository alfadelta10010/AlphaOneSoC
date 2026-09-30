# Only a store to the CLINT may write the CLINT. soc_bus selects it on
# address bits alone and the CLINT decodes addr[15:0], so a decode slip --
# `.we(dmem_we)` without the select, say -- would let every store write the
# CLINT register at the same 16-bit offset: a PSRAM store rewriting
# mtimecmp, a GPIO write setting msip. Nothing else in the suites checked
# that (the PR #5 review's mutant passed all of them).
#
# This programs msip, mtimecmp and mtime, then stores to every other target
# -- GPIO, UART, the syscon window and PSRAM -- at the offsets of those
# registers (0x0000, 0x4000/4, 0xBFF8/C), with values that are harmless
# there but would be seen in the CLINT: msip bit 0 set, mtimecmp changed,
# mtime jumped. Then it checks that the CLINT still holds what it was given
# and that mip.MSIP stayed clear. Interrupts stay off (mstatus.MIE = 0).
#
# The stores:
#   GPIO   +0x0000 OUT  <- 0x09 (its reset value)     msip bit 0
#          +0x4000 OUT  <- 0x09                        mtimecmp[31:0]
#          +0x4004 IN   <- 0x11 (read-only: ignored)   mtimecmp[63:32]
#          +0xBFFC CTRL <- 0x100 (bit 8 is BUSY, read-only; EN = DIV = 0,
#                          as at reset)                mtime[63:32]
#   UART   +0x4004, +0xBFFC  word stores to offsets 4-7: MCR, LSR, MSR, SCR,
#                          all ignored                 mtimecmp[63:32], mtime[63:32]
#   syscon +0x4004 EVENT <- 0 (no cue for this test)   mtimecmp[63:32]
#          +0xBFF8 VALUE <- 0xF0000000 (no check)      mtime[31:0]
#   PSRAM  +0x0000 <- 1, +0x4000 <- 0x5, +0xBFFC <- 0x200
#
# Failure codes: 0x1xx msip, 0x2xx mtimecmp, 0x3xx mtime, 0x4xx mip.
#include "periph.h"

#define CLINT     0x02000000
#define CMP_HI    0x76543210
#define CMP_LO    0xFEDCBA98

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    li   s0, CLINT
    li   t0, 0x4000
    add  s1, s0, t0              # mtimecmp
    li   t0, 0xBFF8
    add  s2, s0, t0              # mtime
    la   t0, trap
    csrw mtvec, t0

    # ---- program the CLINT, and check the writes took ----
    li   t0, CMP_HI
    sw   t0, 4(s1)
    li   t0, CMP_LO
    sw   t0, 0(s1)
    li   t0, 1
    sw   t0, 0(s0)               # msip = 1: the positive control
    lw   t1, 0(s0)
    CHECK t1, 1, 0x101
    csrr t1, mip
    andi t1, t1, 0x8
    CHECK t1, 0x8, 0x401         # MSIP visible in mip
    sw   zero, 0(s0)             # msip = 0
    lw   t1, 0(s0)
    CHECK t1, 0, 0x102
    lw   s3, 0(s2)               # mtime before the stores
    lw   t1, 4(s2)
    CHECK t1, 0, 0x301

    # ---- stores to everything else, at the CLINT's offsets ----
    li   s4, GPIO
    li   t0, 0x09
    sw   t0, 0(s4)               # OUT
    li   t1, 0x4000
    add  t1, s4, t1
    sw   t0, 0(t1)               # OUT (alias)
    li   t0, 0x11
    sw   t0, 4(t1)               # IN
    li   t1, 0xBFFC
    add  t1, s4, t1
    li   t0, 0x100
    sw   t0, 0(t1)               # CTRL

    li   s5, UART
    li   t0, 0x12345678
    li   t1, 0x4004
    add  t1, s5, t1
    sw   t0, 0(t1)               # MCR LSR MSR SCR
    li   t1, 0xBFFC
    add  t1, s5, t1
    sw   t0, 0(t1)               # MCR LSR MSR SCR

    li   t1, 0x4004
    add  t1, s11, t1
    sw   zero, 0(t1)             # syscon EVENT 0
    li   t1, 0xBFF8
    add  t1, s11, t1
    li   t0, 0xF0000000
    sw   t0, 0(t1)               # syscon VALUE

    li   s6, 0x80000000
    li   t0, 1
    sw   t0, 0(s6)
    li   t1, 0x4000
    add  t1, s6, t1
    li   t0, 5
    sw   t0, 0(t1)
    li   t1, 0xBFFC
    add  t1, s6, t1
    li   t0, 0x200
    sw   t0, 0(t1)

    # ---- the CLINT holds what it was given ----
    lw   t1, 0(s0)
    CHECK t1, 0, 0x103           # msip still 0
    csrr t1, mip
    andi t1, t1, 0x8
    CHECK t1, 0, 0x402           # no software interrupt pending
    lw   t1, 0(s1)
    CHECK t1, CMP_LO, 0x201
    lw   t1, 4(s1)
    CHECK t1, CMP_HI, 0x202
    lw   t1, 4(s2)
    CHECK t1, 0, 0x302           # mtime[63:32] untouched
    lw   t1, 0(s2)
    sub  t1, t1, s3              # clocks the stores took: tens of
    li   t2, 100000              # instructions, a few thousand clocks
    bltu t1, t2, 1f
    mv   a7, t1
    li   a6, 0x303               # mtime[31:0] jumped
    j    test_fail
1:
    # GPIO and PSRAM kept what the stores gave them
    lw   t1, 0(s4)
    CHECK t1, 0x09, 0x501
    lw   t1, 0(s6)
    CHECK t1, 1, 0x502
    j    test_pass

trap:
    csrr a7, mcause
    li   a6, 0xEEE
    j    test_fail

    EPILOGUE
