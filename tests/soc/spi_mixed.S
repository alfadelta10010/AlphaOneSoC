# The SSD1331 and an SD card on the one bus (WO-29 8): the OLED initialised
# and 64 pixels (BAUD 5: the device tree's 5208334 Hz), the SD card initialised
# and one block read (BAUD 78 then 2), then 64 pixels to the OLED again. Both
# CS# on OUT, written as whole words with bits 1 and 3 stale, mode 3 throughout.
# N_OLED = 12 commands + 64 + 64 pixel bytes = 140 (the bench's copy is
# tb_soc_periph.v setup_oled). Pixel i = (5 i + 0x21) & 0xFF.
#include "periph.h"
#include "spi_drv.S"
#define OLED_HZ 5208334
#define BAUD_OLED BAUD_OF(OLED_HZ)
#define N_OLED 140
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s1, GPIO
    li   s5, 0
    li   s6, 0
    jal  ra, crc_init
    DELAY 400                          /* RES# low >= 3 us */
    OUTW OUT_DESEL                     /* RES# and VCCEN high */
    DELAY 400
    li   t0, BAUD_OLED
    sw   t0, S_BAUD(s1)
    li   t0, 3
    sw   t0, S_CONTROL(s1)
    li   t0, 1
    sw   t0, G_CTRL(s1)
    jal  ra, oled_init
    jal  ra, oled_pix
    SD_CARD_INIT BAUD_DT
    SD_CMD17 5
    li   a0, 5
    li   a1, 0
    jal  ra, sd_read_block
    OUTW OUT_DESEL
    li   a0, 0xFF
    jal  ra, spi_byte
    li   t0, BAUD_OLED
    sw   t0, S_BAUD(s1)
    jal  ra, oled_pix
    li   t0, N_OLED
    VALUE t0
    VALUE s5
    j    test_pass

oled_init:
    mv   s8, ra
    OUTW OUT_OLED_CMD
    la   a0, oinit
    li   a2, 12
    jal  ra, spi_tx
    OUTW OUT_DESEL
    mv   ra, s8
    ret
oled_pix:
    mv   s8, ra
    la   t3, blkbuf
    li   t1, 0
1:  slli t2, t1, 2
    add  t2, t2, t1                    /* 5 i */
    addi t2, t2, 0x21
    sb   t2, 0(t3)
    addi t3, t3, 1
    addi t1, t1, 1
    li   t2, 64
    bne  t1, t2, 1b
    OUTW OUT_OLED_DATA
    la   a0, blkbuf
    li   a2, 64
    jal  ra, spi_tx
    OUTW OUT_DESEL
    mv   ra, s8
    ret
    .section .rodata
oinit: .byte 0xAE, 0xA0, 0x72, 0xA1, 0x00, 0xA2, 0x00, 0xA4, 0xA8, 0x3F, 0x87, 0x06
    .text
    EPILOGUE
