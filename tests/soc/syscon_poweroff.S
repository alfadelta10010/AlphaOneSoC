# Power-off holds the SoC until the pin reset, whatever the inputs do. Two
# boots, told apart by GPIO IN bit 7 (the bench raises it with the pin reset).
#
#   boot 1  IN[7] = 0, cause 0x1, BOOT_MODE 0: BOOT_MODE = 0x77, cue 0x53,
#           arm the watchdog (TOP 0, kicked once, enabled), then Linux's
#           syscon-poweroff sequence (read FINISH, or in 0x5555, drain, store).
#           The store lands on a fetch in flight, so the power-off cuts a
#           flash read. The bench then watches the SoC held for 5,000 clocks
#           while it moves the inputs and the strap and sends a UART byte, and
#           ends the watch with a two-edge pin reset.
#   boot 2  IN[7] = 1: the pin reset set PIN and nothing else (RESET_CAUSE 0x1),
#           cleared BOOT_MODE (0), re-latched the strap (0), and disabled the
#           watchdog (CR 0, TORR 0xFF). Pass, which powers off again.
#
# Cue: 0x53 = about to power off out of boot 1 (once).
# Failure codes: 0x1nn boot 1, 0x2nn boot 2.
#include "periph.h"

#define W_CR    0x100
#define W_TORR  0x104
#define W_CRR   0x10C

# The power-off store as a whole word at a word boundary, with the next
# instruction in the next word: the core is already fetching it when the store
# completes, so the hold cuts a flash fetch in flight.
.macro REBOOT_ON_FETCH r
    .option push
    .option norvc
    .balign 4
    sw   \r, 0(s11)
    nop
    .option pop
.endm

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    li   t0, GPIO
    lw   t1, G_IN(t0)
    andi t1, t1, 0x80
    bnez t1, boot2
    lw   s0, 4(s11)                  # RESET_CAUSE
    CHECK s0, 0x1, 0x101
    lw   t0, 8(s11)
    CHECK t0, 0, 0x102               # BOOT_MODE
    li   t0, 0x77
    sw   t0, 8(s11)
    EVENT 0x53
    # arm the watchdog last: TORR, kick, CR.EN
    sw   zero, W_TORR(s11)
    li   t0, 0x76
    sw   t0, W_CRR(s11)
    li   t0, 1
    sw   t0, W_CR(s11)
    # syscon-poweroff: read the register (reads 0), or in the value, write it
    lw   t0, 0(s11)
    CHECK t0, 0, 0x103
    li   t2, 0x5555
    or   t1, t0, t2
    DRAIN
    REBOOT_ON_FETCH t1               # power off, cutting a fetch
1:  j    1b

boot2:
    lw   s0, 4(s11)
    CHECK s0, 0x1, 0x201             # PIN, and nothing else
    lw   t0, 8(s11)
    CHECK t0, 0, 0x202               # BOOT_MODE cleared
    lw   t0, 0x10(s11)
    CHECK t0, 0, 0x203               # STRAPS: the pin was 0 at the reset
    lw   t0, W_CR(s11)
    CHECK t0, 0, 0x204
    lw   t0, W_TORR(s11)
    CHECK t0, 0xFF, 0x205
    j    test_pass

    EPILOGUE
