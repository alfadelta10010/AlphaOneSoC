# The watchdog at real scale (TOP 0: a timeout is 2^16 mtime counts). Two boots.
#
#   boot 1  cause 0x1: CR 0 and TORR 0xFF at reset; the dw_wdt start sequence
#           with TOP 0 (TORR, kick, CR.EN); CR reads 1, TORR reads 0; twelve
#           kicks 16,384 mtime counts apart (three timeouts' worth, no reset);
#           a bad kick (0x75) and a CR write of 0 change nothing (CR stays 1);
#           cue 0x56, then spin without kicking. The watchdog reboots the SoC
#           after more than one timeout and at most 1.5 timeouts + 1 clock; the
#           bench predicts the cycle from mtime and prints the interval.
#   boot 2  cause 0x5 (PIN kept, WDT, no SOFT): the watchdog came back
#           disabled with TOP 15, BOOT_MODE survived, W1C WDT clears the bit
#
# VALUE reports CR after the bad kick and the CR write of 0 (the bench wants 1).
# Failure codes: 0x1nn boot 1, 0x2nn boot 2.
#include "periph.h"

#define W_CR    0x100
#define W_TORR  0x104
#define W_CRR   0x10C

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    lw   s0, 4(s11)                  # RESET_CAUSE
    andi t0, s0, 4
    bnez t0, boot2
    CHECK s0, 0x1, 0x101
    lw   t0, W_CR(s11)
    CHECK t0, 0, 0x102
    lw   t0, W_TORR(s11)
    CHECK t0, 0xFF, 0x103
    li   t0, 0x7E
    sw   t0, 8(s11)                  # BOOT_MODE: boot 2 finds it again
    # dw_wdt start: TORR, kick, CR.EN
    sw   zero, W_TORR(s11)
    li   t0, 0x76
    sw   t0, W_CRR(s11)
    li   t0, 1
    sw   t0, W_CR(s11)
    lw   t0, W_CR(s11)
    CHECK t0, 1, 0x104
    lw   t0, W_TORR(s11)
    CHECK t0, 0, 0x105
    # twelve kicks, 16,384 counts apart: at most one tap edge between kicks
    li   s1, 12
2:  DELAY 16384
    li   t0, 0x76
    sw   t0, W_CRR(s11)
    addi s1, s1, -1
    bnez s1, 2b
    li   t0, 0x75
    sw   t0, W_CRR(s11)              # a bad kick reloads nothing
    sw   zero, W_CR(s11)             # EN cannot be cleared
    lw   t0, W_CR(s11)
    CHECK t0, 1, 0x106
    VALUE t0
    EVENT 0x56
3:  j    3b                          # no more kicks

boot2:
    CHECK s0, 0x5, 0x201
    lw   t0, W_CR(s11)
    CHECK t0, 0, 0x202               # disabled again
    lw   t0, W_TORR(s11)
    CHECK t0, 0xFF, 0x203            # TOP 15 again
    lw   t0, 8(s11)
    CHECK t0, 0x7E, 0x204            # BOOT_MODE kept
    li   t0, 4
    sw   t0, 4(s11)                  # W1C WDT
    lw   t0, 4(s11)
    CHECK t0, 0x1, 0x205
    j    test_pass

    EPILOGUE
