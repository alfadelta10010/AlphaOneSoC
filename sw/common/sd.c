/* An SD card in SPI mode on the SPI controller (src/gpio.v), polled.
 * Follows the boot contract (docs/ROADMAP.md 9.1 rules 4 and 5): EN is set with
 * every CS# high (both the card's and the OLED's), at least 74 clocks go out with CS# high
 * before CMD0, and the card is first clocked at BAUD SD_INIT_BAUD (255: 103 kHz at 52.63 MHz; the spec allows 100 to 400 kHz
 * during identification). Blocks are 512 bytes; an SDHC card is addressed by block
 * number (32 bits: SDHC and SDXC cards up to 2 TB), a standard-capacity one by byte (at most 2 GB: a block
 * number from 0x800000 up would wrap the 32-bit byte address, so sd_read and sd_write refuse it). CRC is off in SPI mode except for CMD0
 * and CMD8. */
#include "soc.h"

/* SCK = CLK_HZ / (2 (BAUD + 1)). Identification: the largest BAUD whose SCK
 * is still >= 100 kHz (the spec allows 100 to 400 kHz), capped at the register's 255. Data: BAUD 2, as the device tree caps
 * the card (docs/pins-and-peripherals.md 3: BAUD 1 loses a clock of MISO margin to the pin flop,
 * 2T - 16 ns - R (T = 19.0 ns), which is not positive for the board's ~20-25 ns round trip). */
#define SD_INIT_BAUD    ((CLK_HZ / 200000u - 1u) > 255u ? 255u : (CLK_HZ / 200000u - 1u))
#define SD_DATA_BAUD    2u

int sd_sdhc;
uint32_t sd_blocks;                     /* the card's size in blocks from its CSD (version 2 only); 0 = not known */

#define SPI(o) (*reg32(GPIO_BASE + (o)))

static void cs_low(void)  { SPI(GPIO_OUT) &= ~GPIO_SD_CS; }
static void cs_high(void) { SPI(GPIO_OUT) |= GPIO_SD_CS; }

static uint8_t xfer(uint8_t b)
{
    SPI(GPIO_TXDATA) = b;
    while (!(SPI(GPIO_STATUS) & 1))
        ;
    return SPI(GPIO_RXDATA) & 0xFF;
}

/* A command and its R1 (the first byte with bit 7 clear), CS# left low. */
static uint8_t cmd(uint8_t c, uint32_t arg, uint8_t crc)
{
    xfer(0xFF);
    xfer(0x40 | c);
    xfer(arg >> 24);
    xfer(arg >> 16);
    xfer(arg >> 8);
    xfer(arg);
    xfer(crc);
    uint8_t r = 0xFF;
    for (int i = 0; i < 16 && (r & 0x80); i++)
        r = xfer(0xFF);
    return r;
}

static uint8_t acmd(uint8_t c, uint32_t arg)
{
    cmd(55, 0, 0x01);
    cs_high();
    xfer(0xFF);
    cs_low();
    return cmd(c, arg, 0x01);
}

/* CMD9: the CSD (16 bytes and a CRC16, unchecked). A version 2 CSD (SDHC and SDXC) gives C_SIZE, bits 69:48:
 * the card holds (C_SIZE + 1) * 1024 blocks. A failure leaves sd_blocks 0: the card's own limit still applies. */
static void sd_read_csd(void)
{
    uint8_t csd[16];
    cs_low();
    if (cmd(9, 0, 0x01) == 0x00) {
        int t = 0;
        uint8_t b;
        while ((b = xfer(0xFF)) != 0xFE && t++ < 100000)
            ;
        if (b == 0xFE) {
            for (int i = 0; i < 16; i++)
                csd[i] = xfer(0xFF);
            xfer(0xFF);
            xfer(0xFF);
            if ((csd[0] >> 6) == 1) {
                uint32_t c_size = ((uint32_t)(csd[7] & 0x3F) << 16) | ((uint32_t)csd[8] << 8) | csd[9];
                sd_blocks = c_size >= 0x3FFFFF ? 0xFFFFFFFFu : (c_size + 1) << 10;   /* 2 TB = 2^32 blocks, saturated */
            }
        }
    }
    cs_high();
    xfer(0xFF);
}

int sd_init(void)
{
    uint32_t ocr = 0;
    uint8_t r;

    SPI(GPIO_BAUD) = SD_INIT_BAUD;
    SPI(GPIO_OUT) |= GPIO_SD_CS | GPIO_OLED_CS;     /* rule 4: EN only with every CS# high */
    SPI(GPIO_CONTROL) = 3;                           /* mode 3: SCK idles high, as the card wants */
    SPI(GPIO_SPICTL) = 1;
    for (int i = 0; i < 10; i++)         /* 80 clocks with CS# high */
        xfer(0xFF);
    /* A card left in the middle of a block (rule 5): clock 0xFF with CS# low until it answers
     * 0xFF. The bytes complete a write block that was being received, so that sector is then
     * written with an 0xFF tail; and a card still busy programming for longer than these
     * 520 bytes (4 ms at 122 kHz, a write can take 250 ms) is sent CMD0 while busy. */
    cs_low();
    for (int i = 0; i < 520 && xfer(0xFF) != 0xFF; i++)
        ;
    cs_high();
    xfer(0xFF);

    cs_low();
    r = cmd(0, 0, 0x95);
    cs_high();
    if (r != 0x01)
        return 1;
    xfer(0xFF);
    cs_low();
    r = cmd(8, 0x1AA, 0x87);
    uint32_t hcs = 0;                    /* a v1 card is told HCS = 0 */
    if (r == 0x01) {                     /* v2: R7 returns the voltage and check pattern */
        uint32_t v = 0;
        for (int i = 0; i < 4; i++)
            v = (v << 8) | xfer(0xFF);
        if ((v & 0xFFF) != 0x1AA) {
            cs_high();
            return 2;
        }
        hcs = 0x40000000;
    } else if (!(r & 0x04)) {            /* not v2 and not "illegal command" (v1): no card */
        cs_high();
        return 2;
    }
    cs_high();
    xfer(0xFF);

    for (int i = 0; i < 2000; i++) {     /* ACMD41 until the card leaves idle */
        cs_low();
        r = acmd(41, hcs);
        cs_high();
        xfer(0xFF);
        if (r == 0x00)
            break;
    }
    if (r != 0x00)
        return 3;

    cs_low();
    r = cmd(58, 0, 0x01);
    for (int i = 0; i < 4; i++)
        ocr = (ocr << 8) | xfer(0xFF);
    cs_high();
    xfer(0xFF);
    if (r != 0x00)
        return 4;
    sd_sdhc = (ocr >> 30) & 1;
    if (!sd_sdhc) {
        cs_low();
        r = cmd(16, 512, 0x01);
        cs_high();
        xfer(0xFF);
        if (r != 0x00)
            return 5;
    }
    sd_blocks = 0;
    if (sd_sdhc)
        sd_read_csd();
    /* 8.77 MHz at 52.63 MHz (the device tree's spi-max-frequency): BAUD 1 would be 13.16 MHz, but it is lost to the pin flop (the
     * MISO sample point is inside the chip, the round trip loses a clock, 19.0 ns), so on a board the card's data
     * would arrive too late; BAUD 2 keeps 40 / 35 / 30 ns of margin for round trips of 20 / 25 / 30 ns
     * (4T - 16 ns - R; docs/pins-and-peripherals.md 3). The bench's card has a short round trip: BAUD 1 passes there. */
    SPI(GPIO_BAUD) = SD_DATA_BAUD;
    return 0;
}

/* CRC16-CCITT (x^16 + x^12 + x^5 + 1, start 0), one table lookup a byte: what the card appends to a block. The
 * bitwise loop costs about 4.7 million instructions on a FatFs run (about 40 clocks each here), the table a
 * fifth of that. */
static const uint16_t crc16_tab[256] = {
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50A5, 0x60C6, 0x70E7,
    0x8108, 0x9129, 0xA14A, 0xB16B, 0xC18C, 0xD1AD, 0xE1CE, 0xF1EF,
    0x1231, 0x0210, 0x3273, 0x2252, 0x52B5, 0x4294, 0x72F7, 0x62D6,
    0x9339, 0x8318, 0xB37B, 0xA35A, 0xD3BD, 0xC39C, 0xF3FF, 0xE3DE,
    0x2462, 0x3443, 0x0420, 0x1401, 0x64E6, 0x74C7, 0x44A4, 0x5485,
    0xA56A, 0xB54B, 0x8528, 0x9509, 0xE5EE, 0xF5CF, 0xC5AC, 0xD58D,
    0x3653, 0x2672, 0x1611, 0x0630, 0x76D7, 0x66F6, 0x5695, 0x46B4,
    0xB75B, 0xA77A, 0x9719, 0x8738, 0xF7DF, 0xE7FE, 0xD79D, 0xC7BC,
    0x48C4, 0x58E5, 0x6886, 0x78A7, 0x0840, 0x1861, 0x2802, 0x3823,
    0xC9CC, 0xD9ED, 0xE98E, 0xF9AF, 0x8948, 0x9969, 0xA90A, 0xB92B,
    0x5AF5, 0x4AD4, 0x7AB7, 0x6A96, 0x1A71, 0x0A50, 0x3A33, 0x2A12,
    0xDBFD, 0xCBDC, 0xFBBF, 0xEB9E, 0x9B79, 0x8B58, 0xBB3B, 0xAB1A,
    0x6CA6, 0x7C87, 0x4CE4, 0x5CC5, 0x2C22, 0x3C03, 0x0C60, 0x1C41,
    0xEDAE, 0xFD8F, 0xCDEC, 0xDDCD, 0xAD2A, 0xBD0B, 0x8D68, 0x9D49,
    0x7E97, 0x6EB6, 0x5ED5, 0x4EF4, 0x3E13, 0x2E32, 0x1E51, 0x0E70,
    0xFF9F, 0xEFBE, 0xDFDD, 0xCFFC, 0xBF1B, 0xAF3A, 0x9F59, 0x8F78,
    0x9188, 0x81A9, 0xB1CA, 0xA1EB, 0xD10C, 0xC12D, 0xF14E, 0xE16F,
    0x1080, 0x00A1, 0x30C2, 0x20E3, 0x5004, 0x4025, 0x7046, 0x6067,
    0x83B9, 0x9398, 0xA3FB, 0xB3DA, 0xC33D, 0xD31C, 0xE37F, 0xF35E,
    0x02B1, 0x1290, 0x22F3, 0x32D2, 0x4235, 0x5214, 0x6277, 0x7256,
    0xB5EA, 0xA5CB, 0x95A8, 0x8589, 0xF56E, 0xE54F, 0xD52C, 0xC50D,
    0x34E2, 0x24C3, 0x14A0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
    0xA7DB, 0xB7FA, 0x8799, 0x97B8, 0xE75F, 0xF77E, 0xC71D, 0xD73C,
    0x26D3, 0x36F2, 0x0691, 0x16B0, 0x6657, 0x7676, 0x4615, 0x5634,
    0xD94C, 0xC96D, 0xF90E, 0xE92F, 0x99C8, 0x89E9, 0xB98A, 0xA9AB,
    0x5844, 0x4865, 0x7806, 0x6827, 0x18C0, 0x08E1, 0x3882, 0x28A3,
    0xCB7D, 0xDB5C, 0xEB3F, 0xFB1E, 0x8BF9, 0x9BD8, 0xABBB, 0xBB9A,
    0x4A75, 0x5A54, 0x6A37, 0x7A16, 0x0AF1, 0x1AD0, 0x2AB3, 0x3A92,
    0xFD2E, 0xED0F, 0xDD6C, 0xCD4D, 0xBDAA, 0xAD8B, 0x9DE8, 0x8DC9,
    0x7C26, 0x6C07, 0x5C64, 0x4C45, 0x3CA2, 0x2C83, 0x1CE0, 0x0CC1,
    0xEF1F, 0xFF3E, 0xCF5D, 0xDF7C, 0xAF9B, 0xBFBA, 0x8FD9, 0x9FF8,
    0x6E17, 0x7E36, 0x4E55, 0x5E74, 0x2E93, 0x3EB2, 0x0ED1, 0x1EF0,
};

static uint16_t crc16(uint16_t c, uint8_t b)
{
    return (uint16_t)((c << 8) ^ crc16_tab[(c >> 8) ^ b]);
}

/* One data block of a read, CS# low and the command already answered: wait for the token, take 512 bytes
 * and the CRC16 and check it. 0 = ok, 0x10 | x = the card sent the data error token 0000xxxx, 2 = no token,
 * 0x30 = the CRC16 is wrong. */
static int read_block(uint8_t *p)
{
    for (int t = 0;; t++) {
        uint8_t b = xfer(0xFF);
        if (b == 0xFE)                   /* the data token */
            break;
        if (b != 0xFF)                   /* a data error token, 0000xxxx: the card gave up */
            return 0x10 | (b & 0x0F);
        if (t > 100000)
            return 2;
    }
    uint16_t c = 0;
    for (int i = 0; i < 512; i++) {
        uint8_t b = xfer(0xFF);
        *p++ = b;
        c = crc16(c, b);
    }
    uint16_t got = (uint16_t)(xfer(0xFF) << 8);
    got |= xfer(0xFF);
    return got == c ? 0 : 0x30;
}

int sd_read(uint32_t lba, void *buf)
{
    uint8_t r;
    if (!sd_sdhc && lba >= 0x800000)     /* lba * 512 would wrap */
        return 1;
    cs_low();
    r = cmd(17, sd_sdhc ? lba : lba * 512, 0x01);
    if (r != 0x00) {
        cs_high();
        return 1;
    }
    int rc = read_block(buf);
    cs_high();
    xfer(0xFF);
    return rc;
}

/* The blocks lba .. lba + n - 1 must lie in the card: a standard-capacity one below 2 GB (the byte address is 32
 * bits), any one below the size the CSD gave, and no block number past 2^32 - 1. */
static int range_ok(uint32_t lba, uint32_t n)
{
    uint32_t last = lba + (n - 1);       /* the last block; block 0xFFFFFFFF is a legal one */
    if (n == 0 || last < lba)            /* (n == 0 only matters when the size below is unknown or saturated; for lba > 0 `last < lba` catches it) */
        return 0;
    if (!sd_sdhc && last >= 0x800000)
        return 0;
    if (sd_blocks != 0 && sd_blocks != 0xFFFFFFFFu && last >= sd_blocks)
        return 0;
    return 1;
}

/* CMD12 after a multiple-block transfer: the byte after the command is a stuff byte (it can be the tail of a
 * block that was on its way, so it is not the R1), then R1 and the busy that follows. */
static int stop_transmission(void)
{
    xfer(0xFF);
    xfer(0x40 | 12);
    for (int i = 0; i < 4; i++)
        xfer(0);
    xfer(0x01);
    xfer(0xFF);                          /* the stuff byte */
    uint8_t r = 0xFF;
    for (int i = 0; i < 10 && (r & 0x80); i++)   /* (ChaN polls 10 times) */
        r = xfer(0xFF);
    for (int t = 0; t <= 1000000; t++)   /* the busy of R1b */
        if (xfer(0xFF) == 0xFF)
            return r == 0x00 ? 0 : 1;
    return 3;
}

/* CMD18: n blocks from lba in one transfer, stopped by CMD12. On an error the blocks before it are in buf and the
 * transfer is stopped; the code is sd_read's. */
int sd_read_blocks(uint32_t lba, void *buf, uint32_t n)
{
    uint8_t *p = buf, r;
    int rc = 0;
    if (!range_ok(lba, n))
        return 1;
    cs_low();
    r = cmd(18, sd_sdhc ? lba : lba * 512, 0x01);
    if (r != 0x00) {
        cs_high();
        return 1;
    }
    for (uint32_t i = 0; i < n && !rc; i++, p += 512)
        rc = read_block(p);
    int st = stop_transmission();
    cs_high();
    xfer(0xFF);
    return rc ? rc : st;
}

/* Wait out the busy (DO low) after a data response or the stop token. 0 = done, 3 = the card never finished. */
static int wait_busy(void)
{
    for (int t = 0; t <= 1000000; t++)
        if (xfer(0xFF) == 0xFF)
            return 0;
    return 3;
}

/* CMD13: R1 and the second status byte, both zero when nothing went wrong; the card clears the bits on read. */
static int status_ok(void)
{
    cs_low();
    uint8_t r = cmd(13, 0, 0x01);
    uint8_t st = xfer(0xFF);
    cs_high();
    xfer(0xFF);
    return (r != 0x00 || st != 0x00) ? 0x20 | ((r | st) & 0x0F) : 0;
}

int sd_write(uint32_t lba, const void *buf)
{
    const uint8_t *p = buf;
    uint8_t r;
    if (!sd_sdhc && lba >= 0x800000)     /* lba * 512 would wrap */
        return 1;
    cs_low();
    r = cmd(24, sd_sdhc ? lba : lba * 512, 0x01);
    if (r != 0x00) {
        cs_high();
        return 1;
    }
    xfer(0xFF);
    xfer(0xFE);
    for (int i = 0; i < 512; i++)
        xfer(*p++);
    xfer(0xFF);
    xfer(0xFF);
    r = xfer(0xFF);
    /* Busy (DO low) follows the data response, accepted or not: wait it out before CS# goes high, or the
     * next command meets a card that is still busy. */
    if (wait_busy()) {
        cs_high();
        return 3;
    }
    if ((r & 0x1F) != 0x05) {            /* the data was not accepted (0x0B CRC error, 0x0D write error) */
        cs_high();
        xfer(0xFF);
        /* The card holds the error in its status until CMD13 reads it (the bits clear on read): read it
         * now, or the next good write's CMD13 reports this one. */
        status_ok();
        return 2;
    }
    cs_high();
    xfer(0xFF);

    /* The card has taken the block and finished programming; ask whether it succeeded. */
    return status_ok();
}

/* CMD25: n blocks to lba in one transfer: each block is the token 0xFC, 512 bytes and a CRC16 (not checked in SPI
 * mode, sent as 0xFFFF as sd_write does), answered by a data response and busy; the stop token 0xFD ends it. A
 * block the card refuses ends the transfer (the stop token, then CMD13 reads and clears the error) with code 2;
 * the blocks before it were taken. */
int sd_write_blocks(uint32_t lba, const void *buf, uint32_t n)
{
    const uint8_t *p = buf;
    uint8_t r;
    int rc = 0;
    if (!range_ok(lba, n))
        return 1;
    cs_low();
    r = cmd(25, sd_sdhc ? lba : lba * 512, 0x01);
    if (r != 0x00) {
        cs_high();
        return 1;
    }
    for (uint32_t i = 0; i < n && !rc; i++) {
        xfer(0xFF);
        xfer(0xFC);
        for (int j = 0; j < 512; j++)
            xfer(*p++);
        xfer(0xFF);
        xfer(0xFF);
        r = xfer(0xFF);
        if (wait_busy())
            rc = 3;
        else if ((r & 0x1F) != 0x05)
            rc = 2;
    }
    xfer(0xFD);                          /* stop tran */
    xfer(0xFF);                          /* one byte before the busy */
    if (wait_busy() && !rc)
        rc = 3;
    cs_high();
    xfer(0xFF);
    int st = status_ok();
    return rc ? rc : st;
}
