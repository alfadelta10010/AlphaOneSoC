# syscon's register map, every access shape the core can make (one boot).
# tb/tb_syscon_soc.v checks every load here against its own model as well, so
# the CHECKs below are the program's view of the same table.
#
#   1  reset values, including the watchdog window (loads only: a store into
#      the window here would arm or retime the watchdog)
#   2  read-only and reserved words ignore stores; a 0x7777 / 0x5555 store to
#      one of them is no FINISH
#   3  BOOT_MODE: lane 0 only
#   4  RESET_CAUSE: write-1-to-clear on lane 0 only
#   5  the other 64 KB reads 0, ignores stores and aliases nothing (SYS-002):
#      high addresses, each register offset with one of its bits [15:5] set
#      (bit 8 is the watchdog window), the window's mirrors
#   6  stores to FINISH that must not act: one lane, the wrong half, other
#      status values
#   7  Linux's syscon-reboot-mode read-modify-write of BOOT_MODE
#
# Failure codes: 0x1nn step 1, 0x2nn step 2, 0x3nn steps 3-4, 0x4nn step 5
# (VALUE2 holds the offset), 0x5nn step 6-7.
#include "periph.h"

# word store of `val` to SYSCON + off (off may exceed the 12-bit immediate),
# then a load of it must read 0 (VALUE2 = off on a failure)
.macro SWZ off, val=-1
    li   t1, \off
    add  t1, t1, s11
    li   t2, \val
    sw   t2, 0(t1)
    lw   t3, 0(t1)
    beqz t3, 86f
    li   a7, \off
    li   a6, 0x400
    j    test_fail
86:
.endm
# the same for an offset that is a FINISH alias: also 0x7777 and 0x5555
.macro SWZF off
    SWZ \off
    SWZ \off, 0x7777
    SWZ \off, 0x5555
.endm
# one register offset with each of its alias bits (5-7, 9-15) set
.macro ALIASES off
    SWZF (\off | 0x0020)
    SWZF (\off | 0x0040)
    SWZF (\off | 0x0080)
    SWZF (\off | 0x0200)
    SWZF (\off | 0x0400)
    SWZF (\off | 0x0800)
    SWZF (\off | 0x1000)
    SWZF (\off | 0x2000)
    SWZF (\off | 0x4000)
    SWZF (\off | 0x8000)
.endm
# the register at `off` reads `v`
.macro RD off, v, code
    lw   t0, \off(s11)
    CHECK t0, \v, \code
.endm

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT

    # ---- 1. reset values (the strap pin is 0 in this run) ----
    RD   0x00, 0, 0x101              # FINISH reads 0
    RD   0x04, 0x1, 0x102            # RESET_CAUSE: PIN
    RD   0x08, 0, 0x103              # BOOT_MODE
    RD   0x0C, 0x41315301, 0x104     # CHIP_ID
    RD   0x10, 0, 0x105              # STRAPS
    RD   0x14, 0, 0x106
    RD   0x18, 0, 0x107
    RD   0x1C, 0, 0x108
    RD   0x100, 0, 0x110             # CR
    RD   0x104, 0xFF, 0x111          # TORR: TOP 15
    RD   0x108, 0, 0x112             # CCVR
    RD   0x10C, 0, 0x113             # CRR
    RD   0x110, 0, 0x114             # STAT
    RD   0x114, 0, 0x115             # EOI
    RD   0x1F4, 0x40, 0x116          # COMP_PARAMS_1
    RD   0x118, 0, 0x117
    RD   0x1FC, 0, 0x118

    # ---- 2. read-only and reserved words ----
    li   t1, -1
    sw   t1, 0x0C(s11)
    sw   t1, 0x10(s11)
    sw   t1, 0x14(s11)
    sw   t1, 0x18(s11)
    sw   t1, 0x1C(s11)
    RD   0x0C, 0x41315301, 0x201
    RD   0x10, 0, 0x202
    RD   0x14, 0, 0x203
    RD   0x18, 0, 0x204
    RD   0x1C, 0, 0x205
    li   t1, 0x7777
    sw   t1, 0x0C(s11)
    sw   t1, 0x10(s11)
    sw   t1, 0x14(s11)
    sw   t1, 0x18(s11)
    sw   t1, 0x1C(s11)
    li   t1, 0x5555
    sw   t1, 0x0C(s11)
    sw   t1, 0x10(s11)
    sw   t1, 0x14(s11)
    sw   t1, 0x18(s11)
    sw   t1, 0x1C(s11)
    li   t1, 0x3333
    sw   t1, 0x14(s11)
    sw   t1, 0x1C(s11)
    RD   0x0C, 0x41315301, 0x206
    RD   0x10, 0, 0x207
    RD   0x04, 0x1, 0x208            # still alive, cause untouched

    # ---- 3. BOOT_MODE: lane 0 only ----
    li   t1, 0x123456A5
    sw   t1, 0x08(s11)
    RD   0x08, 0xA5, 0x301
    li   t1, 0x3C
    sb   t1, 0x08(s11)
    RD   0x08, 0x3C, 0x302
    li   t1, 0xFFFF
    sh   t1, 0x0A(s11)               # lanes 2-3
    RD   0x08, 0x3C, 0x303
    sb   t1, 0x09(s11)               # lane 1
    RD   0x08, 0x3C, 0x304
    sb   t1, 0x0B(s11)               # lane 3
    RD   0x08, 0x3C, 0x305
    lbu  t0, 0x08(s11)
    CHECK t0, 0x3C, 0x306            # byte load of lane 0
    lbu  t0, 0x09(s11)
    CHECK t0, 0, 0x307               # lane 1 reads 0

    # ---- 4. RESET_CAUSE: W1C on lane 0 only (the clearing store is after step 5) ----
    sw   zero, 0x04(s11)
    RD   0x04, 0x1, 0x311
    li   t1, 1
    sb   t1, 0x05(s11)               # lane 1
    RD   0x04, 0x1, 0x312
    li   t1, 0x10001
    sh   t1, 0x06(s11)               # lanes 2-3
    RD   0x04, 0x1, 0x313

    # ---- 5. unimplemented words (SYS-002), with RESET_CAUSE still 0x1 ----
    SWZF 0x20
    SWZF 0x3C
    SWZF 0x40
    SWZF 0x7FC
    SWZF 0x800
    SWZF 0x1004
    SWZF 0x1008
    SWZF 0x4004
    SWZF 0x8008
    SWZF 0xBFF8
    SWZF 0xFFFC
    SWZF 0xFFE0
    ALIASES 0x00
    ALIASES 0x04
    ALIASES 0x08
    ALIASES 0x0C
    ALIASES 0x10
    ALIASES 0x14
    ALIASES 0x18
    ALIASES 0x1C
    # the watchdog window's mirrors (bit 9 set), with and without the kick key
    SWZ  0x300
    SWZ  0x300, 0x76
    SWZ  0x304
    SWZ  0x304, 0x76
    SWZ  0x30C
    SWZ  0x30C, 0x76
    SWZ  0x1F4 | 0x200
    SWZ  0x10C | 0x1000
    SWZ  0x10C | 0x4000, 0x76
    SWZ  0x104 | 0x8000, 0x0
    # nothing moved, nothing armed the watchdog
    RD   0x04, 0x1, 0x401
    RD   0x08, 0x3C, 0x402
    RD   0x10, 0, 0x403
    RD   0x0C, 0x41315301, 0x404
    RD   0x100, 0, 0x405
    RD   0x104, 0xFF, 0x406
    # the mailbox words read 0 (stores there are cues, not done here)
    RD   0x7F0, 0, 0x407
    RD   0x7F4, 0, 0x408
    RD   0x7F8, 0, 0x409
    RD   0x7FC, 0, 0x40A
    # now the clearing store of step 4
    li   t1, 1
    sw   t1, 0x04(s11)
    RD   0x04, 0x0, 0x411

    # ---- 6. FINISH stores that must not act ----
    li   t1, 0x77
    sb   t1, 0x00(s11)               # one lane
    sb   t1, 0x01(s11)
    li   t1, 0x55
    sb   t1, 0x00(s11)
    li   t1, 0x33
    sb   t1, 0x00(s11)
    li   t1, 0x7777
    sh   t1, 0x02(s11)               # lanes 2-3: the wrong half
    li   t1, 0x5555
    sh   t1, 0x02(s11)
    li   t1, 0x3333
    sh   t1, 0x02(s11)
    li   t1, 0x7776
    sw   t1, 0x00(s11)               # other statuses
    li   t1, 0x5554
    sw   t1, 0x00(s11)
    li   t1, 0x3332
    sw   t1, 0x00(s11)
    li   t1, 0x7577
    sw   t1, 0x00(s11)
    li   t1, 0x0001
    sw   t1, 0x00(s11)
    li   t1, 0xFFFF
    sw   t1, 0x00(s11)
    li   t1, 0x77770000              # status 0, a code-looking upper half
    sw   t1, 0x00(s11)
    li   t1, 0x55557776
    sw   t1, 0x00(s11)
    RD   0x04, 0x0, 0x501            # still running, nothing changed
    RD   0x00, 0, 0x502

    # ---- 7. Linux syscon-reboot-mode: read, mask 0xff, or in the magic, write ----
    lw   t0, 0x08(s11)
    andi t0, t0, -256
    ori  t0, t0, 0x2
    sw   t0, 0x08(s11)
    RD   0x08, 0x2, 0x511

    j    test_pass

    EPILOGUE
