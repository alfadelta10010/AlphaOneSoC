# The PmodOLEDrgb's SSD1331 brought up through the GPIO block's SPI
# transmitter, the way a driver would: RES# (with VCCEN) held low >= 3 us
# and released, then CS# low and the initialisation commands one store per
# byte, then a 4x2 window and its pixels as data, then Display On.
#
# No BUSY polling between a DATA store and the OUT store that changes D/C
# or raises CS#: the OUT store waits while the byte shifts, and lands half
# an SCK period after its last rising edge (tAH, tCSH). The reviewer's
# sequence -- DATA; OUT(D/C); DATA; DATA; OUT(CS#) -- at DIV 3 and DIV 2,
# then the same with BUSY polled.
#
# Last, one byte at DIV 1 (an 80 ns SCK period at 50 MHz) between cues 9
# and 10: the SSD1331 model must flag it -- the check that its timing
# checks are awake.
#include "periph.h"
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    li   s1, GPIO
    lw   t0, G_OUT(s1)
    CHECK t0, 0x09, 0x201        # reset: CS# high, SCK idle high, RES# low
    lw   t0, G_CTRL(s1)
    CHECK t0, 0x00, 0x202
    DELAY 200                    # RES# low >= 3 us (4 us at 50 MHz)
    li   t0, 0x49
    sw   t0, G_OUT(s1)           # RES# and VCCEN high, CS# high
    DELAY 200                    # >= 3 us before VCC
    li   t0, 0x05
    sw   t0, G_CTRL(s1)          # EN, DIV 2: SCK = clk/8 = 160 ns
    li   t0, 0x48
    sw   t0, G_OUT(s1)           # CS# low, D/C 0: commands
    la   a0, init
    la   a1, init_end
1:  lbu  t0, 0(a0)
    sw   t0, G_DATA(s1)          # one store per byte
    addi a0, a0, 1
    bltu a0, a1, 1b
    li   t0, 0x4C
    sw   t0, G_OUT(s1)           # D/C 1 at once: waits for the last command
    la   a0, pix
    la   a1, pix_end
2:  lbu  t0, 0(a0)
    sw   t0, G_DATA(s1)
    addi a0, a0, 1
    bltu a0, a1, 2b
    li   t0, 0x4D
    sw   t0, G_OUT(s1)           # CS# high at once: waits for the last pixel
    lw   t0, G_CTRL(s1)
    CHECK t0, 0x05, 0x203        # BUSY clear once that store is done

    li   t0, 0x07
    sw   t0, G_CTRL(s1)          # DIV 3
    li   t0, 0x48
    sw   t0, G_OUT(s1)
    li   t0, 0xA4
    li   t1, 0x4C
    li   t2, 0x3C
    li   t3, 0x3D
    li   a2, 0x4D
    sw   t0, G_DATA(s1)          # command
    sw   t1, G_OUT(s1)           # D/C = 1
    sw   t2, G_DATA(s1)          # data
    sw   t3, G_DATA(s1)          # data
    sw   a2, G_OUT(s1)           # CS# = 1
    li   t0, 0x05
    sw   t0, G_CTRL(s1)          # DIV 2, the same again
    li   t0, 0x48
    sw   t0, G_OUT(s1)
    li   t0, 0xA6
    li   t2, 0x5A
    li   t3, 0xA5
    sw   t0, G_DATA(s1)
    sw   t1, G_OUT(s1)
    sw   t2, G_DATA(s1)
    sw   t3, G_DATA(s1)
    sw   a2, G_OUT(s1)

    li   t0, 0x48                # with BUSY polled before each OUT write
    sw   t0, G_OUT(s1)
    li   t0, 0xAF                # Display On
    sw   t0, G_DATA(s1)
3:  lw   t0, G_CTRL(s1)
    andi t0, t0, 0x100
    bnez t0, 3b
    li   t0, 0x4D
    sw   t0, G_OUT(s1)

    EVENT 9
    li   t0, 0x03
    sw   t0, G_CTRL(s1)          # DIV 1: too fast for the SSD1331
    li   t0, 0x48
    sw   t0, G_OUT(s1)
    li   t0, 0xE3                # NOP
    sw   t0, G_DATA(s1)
    li   t0, 0x49
    sw   t0, G_OUT(s1)
    EVENT 10
    li   t0, 0x04
    sw   t0, G_CTRL(s1)          # EN off: out[3] is OUT bit 3 (high) again
    lw   t0, G_OUT(s1)
    CHECK t0, 0x49, 0x204
    j    test_pass
    EPILOGUE

    .section .rodata
init:                            # the PmodOLEDrgb library's sequence
    .byte 0xAE                   # display off
    .byte 0xA0, 0x72             # remap: RGB, 65k colours
    .byte 0xA1, 0x00             # start line
    .byte 0xA2, 0x00             # offset
    .byte 0xA4                   # normal display
    .byte 0xA8, 0x3F             # 1/64 multiplex
    .byte 0xAD, 0x8E             # external VCC
    .byte 0xB0, 0x0B             # power save off
    .byte 0xB1, 0x31             # phase lengths
    .byte 0xB3, 0xF0             # clock divider
    .byte 0x8A, 0x64, 0x8B, 0x78, 0x8C, 0x64   # second precharge A/B/C
    .byte 0xBB, 0x3A             # precharge level
    .byte 0xBE, 0x3E             # VCOMH
    .byte 0x87, 0x06             # master current
    .byte 0x81, 0x91, 0x82, 0x50, 0x83, 0x7D   # contrast A/B/C
    .byte 0x2E                   # scrolling off
    .byte 0x25, 0x00, 0x00, 0x5F, 0x3F         # clear window
    .byte 0x15, 0x10, 0x13       # columns 16-19
    .byte 0x75, 0x08, 0x09       # rows 8-9
init_end:
pix:                             # 8 pixels, RGB565, high byte first
    .byte 0xF8, 0x00, 0x07, 0xE0, 0x00, 0x1F, 0xFF, 0xFF
    .byte 0x00, 0x00, 0x84, 0x10, 0xFF, 0xE0, 0x07, 0xFF
pix_end:
