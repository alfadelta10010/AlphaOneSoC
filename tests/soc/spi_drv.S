/* SPI driver routines and an SD card layer for the SoC programs (WO-29 8).
 * #included by sd_init.S, spi_mixed.S and sd_reboot.S, after periph.h.
 *
 * The driver loop is the Linux spi-oc-tiny polled loop (WO-28 1.1), the three
 * paths: spi_txrx (tx + rx), spi_rx (rx only, 0xFF on MOSI), spi_tx (tx only).
 * Every STATUS wait is bounded (100000 polls), then FINISH fail 0x0E.
 *
 * Registers: s1 = GPIO, s11 = SYSCON (both kept), s5 = bytes checked, s6 =
 * CRC16s checked, s9/s10 = saved ra of the level-2 routines. Leaf routines use
 * t0-t3 and a-registers; sd_* routines call only leaf routines.
 * Fail codes (FINISH (code << 16) | 0x3333):
 *   01 CMD0 R1 timeout   02 CMD0 R1 != 01    03 CMD8 timeout   04 R7 != 0x1AA
 *   05 ACMD41 never ready / R1 timeout       06 CMD58 R1/OCR   07 CMD17 R1
 *   08 data token timeout 09 data differs from the image  0A CRC16 differs
 *   0B CMD24 R1  0C data response  0D write busy timeout  0E STATUS poll timeout
 *   0F CMD18 R1  10 CMD12 R1  11 CMD12 busy timeout
 */
#ifndef CLK_HZ
#define CLK_HZ 62500000
#endif
#ifndef SD_HZ
#define SD_HZ 12500000             /* the device tree's spi-max-frequency for the card */
#endif
#define SD_ID_HZ 400000
#define BAUD_OF(hz) ((((CLK_HZ) + 2 * (hz) - 1) / (2 * (hz))) - 1)   /* the driver's formula */
#define BAUD_ID BAUD_OF(SD_ID_HZ)
#define BAUD_DT BAUD_OF(SD_HZ)

/* whole-word OUT writes with bits 1 and 3 deliberately inverted, as a stale
 * gpio-mmio shadow would write them: bit 7 SD CS#, bit 6 RES#, bit 2 D/C#, bit 0 OLED CS# */
#define OUT_SD_SEL    0x43        /* SD CS# low, the rest high-ish */
#define OUT_DESEL     0xC3        /* both CS# high, RES# high */
#define OUT_OLED_CMD  0xC2        /* OLED CS# low, D/C# 0 */
#define OUT_OLED_DATA 0xC6        /* OLED CS# low, D/C# 1 */

.macro OUTW v
    li   t5, \v
    sw   t5, G_OUT(s1)
.endm

.macro WAIT_ST bit
    li   t0, 100000
88: lw   t1, S_STATUS(s1)
    andi t1, t1, \bit
    bnez t1, 89f
    addi t0, t0, -1
    bnez t0, 88b
    mv   a7, t1
    li   a6, 0x0E
    j    test_fail
89:
.endm

    .text
spi_byte:                              /* a0 = byte out; returns the byte in */
    sb   a0, S_TXDATA(s1)
    WAIT_ST 1
    lbu  a0, S_RXDATA(s1)
    ret

spi_txrx:                              /* a0 = tx, a1 = rx, a2 = len >= 1 */
    lbu  t2, 0(a0)
    sb   t2, S_TXDATA(s1)
    addi a0, a0, 1
    li   t3, 1
1:  bgeu t3, a2, 2f
    lbu  t2, 0(a0)
    sb   t2, S_TXDATA(s1)
    addi a0, a0, 1
    WAIT_ST 2
    lbu  t2, S_TXDATA(s1)
    sb   t2, 0(a1)
    addi a1, a1, 1
    addi t3, t3, 1
    j    1b
2:  WAIT_ST 1
    lbu  t2, S_RXDATA(s1)
    sb   t2, 0(a1)
    ret

spi_rx:                                /* a1 = rx, a2 = len >= 1; 0xFF on MOSI */
    li   t2, 0xFF
    sb   t2, S_TXDATA(s1)
    li   t3, 1
1:  bgeu t3, a2, 2f
    sb   t2, S_TXDATA(s1)
    WAIT_ST 2
    lbu  t2, S_TXDATA(s1)
    sb   t2, 0(a1)
    addi a1, a1, 1
    li   t2, 0xFF
    addi t3, t3, 1
    j    1b
2:  WAIT_ST 1
    lbu  t2, S_RXDATA(s1)
    sb   t2, 0(a1)
    ret

spi_tx:                                /* a0 = tx, a2 = len >= 1 */
    lbu  t2, 0(a0)
    sb   t2, S_TXDATA(s1)
    addi a0, a0, 1
    li   t3, 1
1:  bgeu t3, a2, 2f
    lbu  t2, 0(a0)
    sb   t2, S_TXDATA(s1)
    addi a0, a0, 1
    WAIT_ST 2
    addi t3, t3, 1
    j    1b
2:  WAIT_ST 1
    ret

/* ---- SD layer (all with CS# held low by the caller) ---- */
sd_cmd:                                /* a0 = cmd, a1 = arg, a2 = crc byte */
    mv   s10, ra
    ori  a0, a0, 0x40
    jal  ra, spi_byte
    srli a0, a1, 24
    jal  ra, spi_byte
    srli a0, a1, 16
    andi a0, a0, 0xFF
    jal  ra, spi_byte
    srli a0, a1, 8
    andi a0, a0, 0xFF
    jal  ra, spi_byte
    andi a0, a1, 0xFF
    jal  ra, spi_byte
    mv   a0, a2
    jal  ra, spi_byte
    mv   ra, s10
    ret

sd_r1:                                 /* a3 = timeout fail code; returns R1 in a0 */
    mv   s10, ra
    li   s9, 16
1:  li   a0, 0xFF
    jal  ra, spi_byte
    andi t2, a0, 0x80
    beqz t2, 2f
    addi s9, s9, -1
    bnez s9, 1b
    mv   a7, a0
    mv   a6, a3
    j    test_fail
2:  mv   ra, s10
    ret

sd_token:                              /* a3 = fail code: clock 0xFF until 0xFE (<= 2000 bytes) */
    mv   s10, ra
    li   s9, 2000
1:  li   a0, 0xFF
    jal  ra, spi_byte
    li   t2, 0xFE
    beq  a0, t2, 2f
    addi s9, s9, -1
    bnez s9, 1b
    mv   a7, a0
    mv   a6, a3
    j    test_fail
2:  mv   ra, s10
    ret

sd_busy:                               /* a3 = fail code: clock 0xFF until the card returns 0xFF (<= 5000) */
    mv   s10, ra
    li   s9, 5000
1:  li   a0, 0xFF
    jal  ra, spi_byte
    li   t2, 0xFF
    beq  a0, t2, 2f
    addi s9, s9, -1
    bnez s9, 1b
    mv   a7, a0
    mv   a6, a3
    j    test_fail
2:  mv   ra, s10
    ret

crc_init:                              /* CRC16-CCITT table (poly 0x1021) at crctbl */
    la   t3, crctbl
    li   a4, 0x8000
    li   a5, 0x1021
    li   a3, 0xFFFF
    li   t1, 0
1:  slli t2, t1, 8
    li   t0, 8
2:  and  t5, t2, a4
    slli t2, t2, 1
    and  t2, t2, a3
    beqz t5, 3f
    xor  t2, t2, a5
3:  addi t0, t0, -1
    bnez t0, 2b
    slli t4, t1, 1
    add  t4, t4, t3
    sh   t2, 0(t4)
    addi t1, t1, 1
    li   t4, 256
    bne  t1, t4, 1b
    la   t3, ffbuf                     /* 16 bytes of 0xFF for idle clocks */
    li   t1, 16
    li   t2, 0xFF
4:  sb   t2, 0(t3)
    addi t3, t3, 1
    addi t1, t1, -1
    bnez t1, 4b
    ret

/* image byte i of block L (the SD model's formula): a0 = L, a1 = xor mask; fills blkbuf
 * and, in t2, the CRC16 of it */
sd_fill:
    li   t0, 0x35
    mul  t0, a0, t0
    andi t0, t0, 0xFF
    la   t6, blkbuf
    li   t1, 0
    li   t2, 0
    la   t3, crctbl
1:  andi t5, t1, 0xFF
    xor  t5, t5, t0
    srli a4, t1, 8
    neg  a4, a4
    andi a4, a4, 0xA5
    xor  t5, t5, a4
    xor  t5, t5, a1
    sb   t5, 0(t6)
    srli a4, t2, 8
    xor  a4, a4, t5
    slli a4, a4, 1
    add  a4, a4, t3
    lhu  a4, 0(a4)
    slli t2, t2, 24
    srli t2, t2, 16
    xor  t2, t2, a4
    addi t6, t6, 1
    addi t1, t1, 1
    li   a4, 512
    bne  t1, a4, 1b
    ret

sd_read_block:                         /* a0 = L, a1 = xor mask; after the token: 512 bytes + CRC16, checked */
    mv   s9, ra
    mv   s8, a0
    mv   s7, a1
    la   a1, blkbuf
    li   a2, 512
    jal  ra, spi_rx
    la   a1, crcbuf
    li   a2, 2
    jal  ra, spi_rx
    mv   a0, s8                        /* the expected image and its CRC16 into ebuf */
    mv   a1, s7
    jal  ra, sd_fill_exp
    la   t3, crcbuf
    lbu  a4, 0(t3)
    lbu  a5, 1(t3)
    slli a4, a4, 8
    or   a4, a4, a5
    beq  a4, t2, 3f
    mv   a7, a4
    li   a6, 0x0A
    j    test_fail
3:  addi s5, s5, 512
    addi s6, s6, 1
    mv   ra, s9
    ret

/* like sd_fill, but compares with blkbuf (the received block) instead of storing; t2 = CRC16 of the
 * received bytes */
sd_fill_exp:
    li   t0, 0x35
    mul  t0, a0, t0
    andi t0, t0, 0xFF
    la   t6, blkbuf
    li   t1, 0
    li   t2, 0
    la   t3, crctbl
1:  lbu  t4, 0(t6)
    andi t5, t1, 0xFF
    xor  t5, t5, t0
    srli a4, t1, 8
    neg  a4, a4
    andi a4, a4, 0xA5
    xor  t5, t5, a4
    xor  t5, t5, a1
    beq  t4, t5, 2f
    slli a7, t1, 16
    or   a7, a7, t4
    li   a6, 0x09
    j    test_fail
2:  srli a4, t2, 8
    xor  a4, a4, t4
    slli a4, a4, 1
    add  a4, a4, t3
    lhu  a4, 0(a4)
    slli t2, t2, 24
    srli t2, t2, 16
    xor  t2, t2, a4
    addi t6, t6, 1
    addi t1, t1, 1
    li   a4, 512
    bne  t1, a4, 1b
    ret

sd_write_block:                        /* a0 = L, a1 = xor mask; after the CMD24 R1: gap, token, 512, CRC16, response, busy */
    mv   s8, ra
    jal  ra, sd_fill                   /* blkbuf and t2 = CRC16 */
    la   t3, crcbuf
    srli t4, t2, 8
    sb   t4, 0(t3)
    sb   t2, 1(t3)
    li   a0, 0xFF
    jal  ra, spi_byte
    li   a0, 0xFE
    jal  ra, spi_byte
    la   a0, blkbuf
    li   a2, 512
    jal  ra, spi_tx
    la   a0, crcbuf
    li   a2, 2
    jal  ra, spi_tx
    li   a0, 0xFF
    jal  ra, spi_byte
    andi a7, a0, 0x1F
    li   t2, 0x05
    beq  a7, t2, 1f
    li   a6, 0x0C
    j    test_fail
1:  li   a3, 0x0D
    jal  ra, sd_busy
    mv   ra, s8
    ret

/* power-up to ready: 80 clocks, CMD0, CMD8, ACMD41, CMD58; leaves CS# low at BAUD `\baud` */
.macro SD_CARD_INIT baud
    li   t0, BAUD_ID
    sw   t0, S_BAUD(s1)
    li   t0, 3
    sw   t0, S_CONTROL(s1)
    li   t0, 1
    sw   t0, G_CTRL(s1)                /* EN */
    OUTW OUT_DESEL
    la   a0, ffbuf
    li   a2, 10
    jal  ra, spi_tx                    /* 80 clocks with CS# high and DI high */
    OUTW OUT_SD_SEL
    li   a0, 0
    li   a1, 0
    li   a2, 0x95
    jal  ra, sd_cmd
    li   a3, 0x01
    jal  ra, sd_r1
    CHECK a0, 0x01, 0x02
    li   a0, 8
    li   a1, 0x1AA
    li   a2, 0x87
    jal  ra, sd_cmd
    li   a3, 0x03
    jal  ra, sd_r1
    li   s3, 0
    li   s4, 4
7:  li   a0, 0xFF
    jal  ra, spi_byte
    slli s3, s3, 8
    or   s3, s3, a0
    addi s4, s4, -1
    bnez s4, 7b
    CHECK s3, 0x1AA, 0x04              /* R7: 00 00 01 AA (the R1 byte is not part of it) */
    li   s2, 1000
6:  li   a0, 55
    li   a1, 0
    li   a2, 0xFF
    jal  ra, sd_cmd
    li   a3, 0x05
    jal  ra, sd_r1
    li   a0, 41
    li   a1, 0x40000000
    li   a2, 0xFF
    jal  ra, sd_cmd
    li   a3, 0x05
    jal  ra, sd_r1
    beqz a0, 5f
    addi s2, s2, -1
    bnez s2, 6b
    li   a6, 0x05
    mv   a7, a0
    j    test_fail
5:  li   a0, 58
    li   a1, 0
    li   a2, 0xFF
    jal  ra, sd_cmd
    li   a3, 0x06
    jal  ra, sd_r1
    CHECK a0, 0x00, 0x06
    li   s3, 0
    li   s4, 4
7:  li   a0, 0xFF
    jal  ra, spi_byte
    slli s3, s3, 8
    or   s3, s3, a0
    addi s4, s4, -1
    bnez s4, 7b
    srli t0, s3, 24
    andi t0, t0, 0xC0
    CHECK t0, 0xC0, 0x06               /* OCR bits 31 and 30 */
    OUTW OUT_DESEL
    li   a0, 0xFF
    jal  ra, spi_byte                  /* 8 clocks after CS# high */
    li   t0, \baud
    sw   t0, S_BAUD(s1)
    OUTW OUT_SD_SEL
.endm

.macro SD_CMD17 blk
    li   a0, 17
    li   a1, \blk
    li   a2, 0xFF
    jal  ra, sd_cmd
    li   a3, 0x07
    jal  ra, sd_r1
    CHECK a0, 0x00, 0x07
    li   a3, 0x08
    jal  ra, sd_token
.endm

    .section .bss
    .balign 4
blkbuf: .skip 512
crctbl: .skip 512
crcbuf: .skip 4
ffbuf:  .skip 16
    .text
