# A syscon reboot with the 4x4 blocks dirty (SF4): every block that is new in the 4x4 SoC is left in a non-reset state,
# the SoC is rebooted, and boot 2 reads each of them back at its reset value. Boot 2 is told from boot 1 by BOOT_MODE
# (0x5A, which a reboot keeps); PSRAM keeps its content, so a magic word written in boot 1 must still be there.
#   boot 1  PLIC: priorities 1, enable word 0x2A (sources 1, 3, 5), threshold 1; UART: FIFO on (FCR 1), IER 1, MCR 0x0D;
#           pinmux pin 6 = PWM0 (code 4); PWM0: enalways, scale 15, cmp0 0 (ip[0] set at once and held for 2^31 clocks; the PWM has no interrupt, so source 5 never pends);
#           gamepad ie = 1 and a 12-bit frame from the bench (cue 1: chg set, source 3 pending, and 3
#           characters into the RX FIFO, source 1 pending); GPIO IN_IE = 0xFF and pin 7 toggled at cue 1 (IN_IP[7],
#           source 4 pending); watchdog EN | RMOD (top 15); CACHE_CTL.EN = 1 with a
#           routine run from PSRAM (a filled line); one pending source claimed and not completed; a THR byte (0xFF)
#           in flight; then the reboot store.
#   boot 2  PLIC pending / enable / threshold / claim 0 and MEIP clear; UART IER 0, IIR 1 (no FIFO bits, nothing
#           pending), MCR 2, LSR 0x60 (RX FIFO empty); PINMUX 0; PWM CFG 0; GPSTAT 0; GPIO IN_IP 0 (pin 7 still high: no phantom edge) and IN_IE 0; WDT CR and STAT 0;
#           CACHE_CTL bit 1 reads 1 and the upper bits 0 (EN itself is checked by the bench at cue 2: 0 unless +CACHE_EN); the magic word in PSRAM; cue 2: the bench checks the pins are the
#           default map (uo_out = 0x39).
# Failure codes: 0x1nn boot 1, 0x2nn boot 2.
#include "periph4.h"
#define CACHE_CTL 0x10020024
#define CODE      0x80003000
#define MAGIC     0x80004000
#define MAGIC_V   0x600D5EED
#define WDT_CR    0x100
#define WDT_TORR  0x104
#define WDT_STAT  0x110

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, PWM
    li   s1, UART
    lw   t0, 8(s11)                  # BOOT_MODE
    li   t1, 0x5A
    beq  t0, t1, boot2
    bnez t0, bad_mode

boot1:
    lw   t0, 4(s11)
    CHECK t0, 0x1, 0x101             # RESET_CAUSE: power-on
    li   t0, MAGIC
    li   t1, MAGIC_V
    sw   t1, 0(t0)
    li   t0, CODE                    # a routine to run from PSRAM: addi a0, zero, 5; ret
    li   t1, 0x00500513
    sw   t1, 0(t0)
    li   t1, 0x00008067
    sw   t1, 4(t0)
    PLIC_SETUP 0x2A
    li   t0, 1
    sw   t0, 0(a4)                   # threshold 1
    li   t0, 0x01
    sb   t0, FCR(s1)                 # FIFO on
    sb   t0, IER(s1)                 # RX data interrupt
    li   t0, 0x0D
    sb   t0, MCR(s1)
    li   t0, 4 << 24
    li   t1, PINMUX
    sw   t0, 0(t1)                   # pin 6 = PWM0
    li   t0, 0
    sw   t0, PWM_CMP0(s0)
    li   t0, 0x100F
    sw   t0, PWM_CFG(s0)
    li   t0, G_PADSTAT
    li   t1, GPIO
    add  t1, t1, t0
    li   t0, 2
    sw   t0, 0(t1)                   # gamepad ie
    li   t1, GPIO
    li   t0, 0xFF
    sw   t0, 0x18(t1)                # IN_IE: every bit
    li   t0, 0x04
    sw   t0, 0x1C(t1)                # W1C of a bit that is not pending: no effect
    li   t0, 15
    sw   t0, WDT_TORR(s11)
    li   t0, 3
    sw   t0, WDT_CR(s11)             # EN | RMOD
    li   t0, 1
    li   t1, CACHE_CTL
    sw   t0, 0(t1)
    li   t0, CODE
    jalr ra, 0(t0)
    CHECK a0, 5, 0x102               # the routine ran from PSRAM
    CUE 1, 3000                      # the bench: a gamepad frame, 3 characters and pin 7 toggled
    li   t1, GPIO
    lw   t0, 0x1C(t1)
    andi t0, t0, 0x80
    CHECK t0, 0x80, 0x10A            # IN_IP: pin 7 changed (gamepad, RX and strap pins may have set others)
    lw   t0, 0x18(t1)
    CHECK t0, 0xFF, 0x10B            # IN_IE
    li   t1, GPIO
    lw   t0, G_PADSTAT(t1)
    CHECK t0, 3, 0x103               # chg | ie
    lbu  t0, LSR(s1)
    andi t0, t0, 1
    CHECK t0, 1, 0x104               # RX FIFO not empty
    li   t0, PLIC + PL_PEND
    lw   t0, 0(t0)
    andi t0, t0, 0x3A
    CHECK t0, 0x1A, 0x105            # UART, gamepad and GPIO input change pending; PWM0 (source 5) never pends
    lw   t0, 4(a4)                   # claim, not completed
    CHECK t0, 1, 0x106
    li   t0, PLIC + PL_PEND
    lw   t0, 0(t0)
    andi t0, t0, 0x38
    CHECK t0, 0x18, 0x107
    lw   t0, PWM_CFG(s0)
    srli t0, t0, 28
    andi t0, t0, 1
    CHECK t0, 1, 0x108               # PWM ip[0]
    li   t0, 0xFF
    sb   t0, THR(s1)                 # a character in flight (all ones: a cut frame still reads 0xFF)
    DELAY 80
    li   t0, 0x5A
    sw   t0, 8(s11)
    li   t1, 0x7777
    .option push
    .option norvc
    .balign 4
    sw   t1, 0(s11)
    nop
    .option pop
1:  j    1b

boot2:
    lw   t0, 4(s11)
    CHECK t0, 0x3, 0x201             # RESET_CAUSE: SOFT
    li   t0, MAGIC
    lw   t0, 0(t0)
    CHECK t0, MAGIC_V, 0x202         # PSRAM kept its content
    li   s2, PLIC
    li   a4, PLIC + PL_CTX
    li   t1, PLIC + PL_PEND
    lw   t0, 0(t1)
    CHECK t0, 0, 0x203
    li   t1, PLIC + PL_EN
    lw   t0, 0(t1)
    CHECK t0, 0, 0x204
    lw   t0, 0(a4)
    CHECK t0, 0, 0x205               # threshold
    lw   t0, 4(a4)
    CHECK t0, 0, 0x206               # claim
    csrr t0, mip
    srli t0, t0, 11
    andi t0, t0, 1
    CHECK t0, 0, 0x207               # MEIP
    lbu  t0, IER(s1)
    CHECK t0, 0, 0x208
    lbu  t0, IIR(s1)
    CHECK t0, 1, 0x209
    lbu  t0, MCR(s1)
    CHECK t0, 2, 0x20A
    lbu  t0, LSR(s1)
    CHECK t0, 0x60, 0x20B            # empty RX FIFO, transmitter idle
    li   t1, PINMUX
    lw   t0, 0(t1)
    CHECK t0, 0, 0x20C
    lw   t0, PWM_CFG(s0)
    CHECK t0, 0, 0x20D
    li   t1, GPIO
    lw   t0, G_PADSTAT(t1)
    CHECK t0, 0, 0x20F
    li   t1, GPIO
    lw   t0, 0x1C(t1)
    CHECK t0, 0, 0x213               # IN_IP cleared by the reset, no phantom edge with pin 7 held high
    lw   t0, 0x18(t1)
    CHECK t0, 0, 0x214               # IN_IE
    lw   t0, WDT_CR(s11)
    CHECK t0, 0, 0x210
    lw   t0, WDT_STAT(s11)
    CHECK t0, 0, 0x211
    li   t1, CACHE_CTL
    lw   t0, 0(t1)
    andi t0, t0, -2                  # (a bench run with +CACHE_EN forces EN: the bench checks the flop itself at cue 2)
    CHECK t0, 2, 0x212
    CUE 2, 400                       # the bench: the pins are the default map
    j    test_pass

bad_mode:
    li   a6, 0x100
    mv   a7, t0
    j    test_fail
    EPILOGUE
