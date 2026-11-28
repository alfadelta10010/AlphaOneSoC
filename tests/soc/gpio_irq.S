# GPIO input-change interrupt (IN_IE +0x18, IN_IP +0x1C) through the PLIC (source 4).
# The bench (cues 1-5) sets, in order, gpio_in[7], [2], [0], [4], and clears [2] again; every cue is
# one edge of one pin, so IN_IP must show exactly that bit. Polled through mip (mstatus.MIE off).
#   start   IN_IP = 0 and IN_IE = 0 after reset (pins idle low); IE = 0x91 (bits 7, 4, 0) reads back;
#           no MEIP; slots 0x10 / 0x14 are not this block's (the SoC bus carves them out: gamepad)
#   cue 1   bit 7 rises: MEIP, claim 4, IP = 0x80; W1C of 0x80 drops it; complete; MEIP clear
#   cue 2   bit 2 rises with IE[2] = 0: IP = 0x04 but no MEIP, claim reads 0; a W1C of bits that are
#           not set (0x91) leaves it; W1C 0x04 clears it
#   cue 3   bit 0 rises, `wfi` wakes on the edge: claim 4, IP = 0x01, clear, complete
#   cue 4   bit 4 rises (the gamepad pin, model idle): the same
#   cue 5   bit 2 falls with IE[2] = 0: IP = 0x04, no MEIP; then IE = 0x95 raises MEIP at once (the
#           edge was pending): claim 4, clear, complete, IE back to 0
#include "periph4.h"
#define G_IE 0x18
#define G_IP 0x1C
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, GPIO
    PLIC_SETUP (1 << SRC_GPIO)
#ifdef IP_CLEAR_FIRST
    # The pins bench (tb_tt_um) gives the chip the demo board's two-clock power-up reset: the input synchroniser is
    # never reset, so IN_IP can show phantom bits on the first read (docs/pins-and-peripherals.md, IN_IP). The
    # documented recipe: clear IN_IP (W1C) first. Everything after it is checked as before.
    li   t0, 0xFF
    sw   t0, G_IP(s0)
#endif
    lw   t0, G_IP(s0)
    CHECK t0, 0, 0x01
    lw   t0, G_IE(s0)
    CHECK t0, 0, 0x02
    lw   t0, 0x10(s0)
    CHECK t0, 0, 0x03
    lw   t0, 0x14(s0)
    andi t0, t0, 0x1              # GPSTAT.chg of the gamepad carve: no pad frame yet
    CHECK t0, 0, 0x04
    li   t0, 0x91
    sw   t0, G_IE(s0)
    lw   t0, G_IE(s0)
    CHECK t0, 0x91, 0x05
    NO_MEIP 0x06

    # cue 1: IE bit set, MEIP, claim, W1C
    EVENT_P 1
    WAIT_MEIP 0x10
    CLAIM SRC_GPIO, 0x11
    lw   t1, G_IP(s0)
    CHECK t1, 0x80, 0x12
    li   t1, 0x80
    sw   t1, G_IP(s0)
    lw   t1, G_IP(s0)
    CHECK t1, 0, 0x13
    COMPLETE
    NO_MEIP 0x14

    # cue 2: IE bit clear: IP sets, no interrupt
    EVENT_P 2
    DELAY 200
    lw   t1, G_IP(s0)
    CHECK t1, 0x04, 0x20
    NO_MEIP 0x21
    CLAIM 0, 0x22
    li   t1, 0x91
    sw   t1, G_IP(s0)             # W1C of other bits: bit 2 survives
    lw   t1, G_IP(s0)
    CHECK t1, 0x04, 0x23
    li   t1, 0x04
    sw   t1, G_IP(s0)
    lw   t1, G_IP(s0)
    CHECK t1, 0, 0x24

    # cue 3: wfi wakes on the edge
#ifdef MB_UART
    EVENT_NW 3                    # no wait: the wfi below is the wait
#else
    EVENT 3
#endif
    wfi
    WAIT_MEIP 0x30
    CLAIM SRC_GPIO, 0x31
    lw   t1, G_IP(s0)
    CHECK t1, 0x01, 0x32
    li   t1, 0x01
    sw   t1, G_IP(s0)
    COMPLETE
    NO_MEIP 0x33

    # cue 4: the gamepad pin
    EVENT_P 4
    WAIT_MEIP 0x40
    CLAIM SRC_GPIO, 0x41
    lw   t1, G_IP(s0)
    CHECK t1, 0x10, 0x42
    li   t1, 0x10
    sw   t1, G_IP(s0)
    COMPLETE
    NO_MEIP 0x43

    # cue 5: a falling edge pends with IE = 0; enabling it fires
    EVENT_P 5
    DELAY 200
    lw   t1, G_IP(s0)
    CHECK t1, 0x04, 0x50
    NO_MEIP 0x51
    li   t1, 0x95
    sw   t1, G_IE(s0)
    DELAY 50
    WAIT_MEIP 0x52
    CLAIM SRC_GPIO, 0x53
    li   t1, 0x04
    sw   t1, G_IP(s0)
    COMPLETE
    sw   zero, G_IE(s0)
    lw   t1, G_IP(s0)
    CHECK t1, 0, 0x54
    NO_MEIP 0x55
    j    test_pass
    EPILOGUE
