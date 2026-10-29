# A pin reset inside a reboot hold leaves only PIN in RESET_CAUSE. Four boots,
# told apart by GPIO IN bits 7 and 6 (the bench raises them with its pin
# resets), RESET_CAUSE.SOFT and BOOT_MODE.
#
#   boot 1  IN[7:6] = 00, cause 0x1, bm 0: BOOT_MODE = 0x11, W1C PIN (cause 0),
#           cue 0x54, reboot with a whole-word store on a fetch. The bench cuts
#           that reboot's hold with a two-edge pin reset (E2-E3).
#   boot 2  IN[7:6] = 10, cause 0x1 (PIN, no SOFT: the pin reset ended the
#           reboot), bm 0: cue 0x55, a clean reboot with sw 0x7777.
#   boot 3  IN[7:6] = 10, cause 0x3, bm 0: W1C both (cause 0), cue 0x57, arm
#           the watchdog with TOP 0 and spin without kicking. The bench cuts
#           the watchdog reboot's hold with a two-edge pin reset (E1-E2).
#   boot 4  IN[7:6] = 11, cause 0x1 (the pin reset wins: WDT cleared, PIN set),
#           CR 0, TORR 0xFF. Pass.
#
# Cues: 0x54, 0x55, 0x57 in that order.
# Failure codes: 0x1nn boot 1, 0x2nn boot 2, 0x3nn boot 3, 0x4nn boot 4.
#include "periph.h"

#define W_CR    0x100
#define W_TORR  0x104
#define W_CRR   0x10C

# The reboot store as a whole word at a word boundary, with the next
# instruction in the next word (see syscon_reboot.S).
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
    MB_INIT
    li   t0, GPIO
    lw   t1, G_IN(t0)
    andi t2, t1, 0x80
    beqz t2, boot1
    andi t2, t1, 0x40
    bnez t2, boot4
    lw   s0, 4(s11)                  # RESET_CAUSE
    andi t0, s0, 2
    bnez t0, boot3

boot2:
    CHECK s0, 0x1, 0x201             # PIN only: the pin reset ended the reboot
    lw   t0, 8(s11)
    CHECK t0, 0, 0x202               # BOOT_MODE
    EVENT_P 0x55
    li   t1, 0x7777
    sw   t1, 0(s11)                  # a clean reboot
1:  j    1b

boot1:
    lw   s0, 4(s11)
    CHECK s0, 0x1, 0x101
    lw   t0, 8(s11)
    CHECK t0, 0, 0x102
    li   t0, 0x11
    sw   t0, 8(s11)
    li   t0, 1
    sw   t0, 4(s11)                  # W1C PIN
    lw   t0, 4(s11)
    CHECK t0, 0, 0x103
    EVENT_P 0x54
    li   t1, 0x7777
    REBOOT_ON_FETCH t1               # reboot, cut by the bench's pin reset
1:  j    1b

boot3:
    CHECK s0, 0x3, 0x301             # SOFT from boot 2's reboot, PIN kept
    lw   t0, 8(s11)
    CHECK t0, 0, 0x302
    li   t0, 3
    sw   t0, 4(s11)                  # W1C both
    lw   t0, 4(s11)
    CHECK t0, 0, 0x303
    EVENT_P 0x57
    sw   zero, W_TORR(s11)           # TOP 0
    li   t0, 0x76
    sw   t0, W_CRR(s11)
    li   t0, 1
    sw   t0, W_CR(s11)
1:  j    1b                          # no kicks

boot4:
    lw   s0, 4(s11)
    CHECK s0, 0x1, 0x401             # PIN, not WDT
    lw   t0, W_CR(s11)
    CHECK t0, 0, 0x402
    lw   t0, W_TORR(s11)
    CHECK t0, 0xFF, 0x403
    j    test_pass

    EPILOGUE
