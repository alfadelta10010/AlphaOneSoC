# Twelve watchdog reboots on a busy bus: the reset lands on a QSPI transaction
# in flight, including between the two halves of a page-split PSRAM fetch,
# where mem_ctrl's `second` flop would replay a bogus second half into the next
# boot if it were not on the SoC reset. A FINISH reboot never lands there, the
# watchdog does.
#
# Every boot: BOOT_MODE counts the boots (it survives a reboot). At 12, pass.
# Otherwise BOOT_MODE += 1, the spin code is copied to PSRAM (a reboot re-runs
# the PSRAM reset, so the copy is made every boot), then the boot waits
# BOOT_MODE x 7 iterations of a short loop (moves the fire's phase against the
# fetch), arms the watchdog (TORR 0, kick, EN) and spins without kicking:
#   odd boots   on `jal x0, 0` at 0x800003FE: the instruction straddles the
#               1 KB page boundary, so every fetch of it is split in two
#               PSRAM reads and a fire can land between them
#   even boots  on two PSRAM loads from flash code (the other PSRAM chip), so
#               a fire can land on a data transaction
# After every reboot the bench checks the first fetch at 0x2000_0000 returns
# the program's first instruction; the program checks RESET_CAUSE.WDT.
#
# Failure codes: 0x101 cause 0x1 expected on the first boot, 0x102 WDT bit
# missing on a later one.
#include "periph.h"

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    lw   s0, 8(s11)                  # BOOT_MODE: boots so far
    lw   t1, 4(s11)                  # RESET_CAUSE
    bnez s0, later
    CHECK t1, 0x1, 0x101
    j    go
later:
    andi t1, t1, 4
    bnez t1, go
    mv   a7, s0
    li   a6, 0x102
    j    test_fail
go:
    li   t0, 12
    bge  s0, t0, test_pass
    addi s1, s0, 1
    sw   s1, 8(s11)
    li   a0, 0x800003FC
    li   t1, 0x006f0000              # bytes 6F 00 at 0x800003FE: low half of jal x0, 0
    sw   t1, 0(a0)
    li   a1, 0x80000400
    sw   zero, 0(a1)                 # its upper half
    fence.i
    slli t2, s1, 3
    sub  t2, t2, s1                  # BOOT_MODE x 7
1:  addi t2, t2, -1
    bgtz t2, 1b
    li   a2, SYSCON + 0x100
    sw   zero, 4(a2)                 # TORR: TOP 0
    li   t0, 0x76
    sw   t0, 12(a2)                  # kick
    li   t0, 1
    sw   t0, 0(a2)                   # EN
    andi t2, s1, 1
    beqz t2, even
    li   t3, 0x800003FE
    jr   t3                          # odd boot: spin on the split instruction
even:
    li   s2, 0x80800000              # the other PSRAM chip
2:  lw   t0, 0(s2)
    lw   t1, 4(s2)
    j    2b

    EPILOGUE
