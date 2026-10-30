# An SD card through the SPI controller, the way mmc_spi would drive it (WO-29 8):
# 80 clocks with CS# high, CMD0, CMD8, CMD55 + ACMD41 until ready, CMD58, the
# bus to the device-tree speed, CMD17 of block 5 compared byte by byte with
# the card's image formula and its CRC16, CMD24 of block 9 with the complemented
# image, CMD17 of block 9 back, CMD18 from block 2 for two blocks, CMD12.
# 16 commands, 4 blocks read (2048 bytes, 4 CRC16s), 1 written with SD_BUSY=3.
# Built with -DSD_HZ=15625000 it runs the data phase at BAUD 1 (sd_b1).
# Reports through the mailbox: VALUE bytes checked, VALUE CRC16s checked,
# VALUE the BAUD the data phase used.
#include "periph.h"
#include "spi_drv.S"
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s1, GPIO
    li   s5, 0
    li   s6, 0
    jal  ra, crc_init
    SD_CARD_INIT BAUD_DT
    SD_CMD17 5
    li   a0, 5
    li   a1, 0
    jal  ra, sd_read_block
    li   a0, 24
    li   a1, 9
    li   a2, 0xFF
    jal  ra, sd_cmd
    li   a3, 0x0B
    jal  ra, sd_r1
    CHECK a0, 0x00, 0x0B
    li   a0, 9
    li   a1, 0xFF
    jal  ra, sd_write_block
    SD_CMD17 9
    li   a0, 9
    li   a1, 0xFF
    jal  ra, sd_read_block
    li   a0, 18
    li   a1, 2
    li   a2, 0xFF
    jal  ra, sd_cmd
    li   a3, 0x0F
    jal  ra, sd_r1
    CHECK a0, 0x00, 0x0F
    li   a3, 0x08
    jal  ra, sd_token
    li   a0, 2
    li   a1, 0
    jal  ra, sd_read_block
    li   a3, 0x08
    jal  ra, sd_token
    li   a0, 3
    li   a1, 0
    jal  ra, sd_read_block
    li   a0, 12
    li   a1, 0
    li   a2, 0xFF
    jal  ra, sd_cmd
    li   a3, 0x10
    jal  ra, sd_r1                     /* the stuff byte is 0xFF, then R1 = 0 */
    li   a3, 0x11
    jal  ra, sd_busy
    OUTW OUT_DESEL
    li   a0, 0xFF
    jal  ra, spi_byte
    VALUE s5
    VALUE s6
    lw   t0, S_BAUD(s1)
    VALUE t0
    j    test_pass
    EPILOGUE
