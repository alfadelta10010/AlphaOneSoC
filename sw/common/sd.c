/* An SD card in SPI mode on the SPI controller (src/gpio.v), polled.
 * Follows the boot contract (docs/ROADMAP.md 9.1 rules 4 and 5): EN is set with
 * every CS# high (both the card's and the OLED's), at least 74 clocks go out with CS# high
 * before CMD0, and the card is first clocked at BAUD 0xFF (122 kHz at 62.5 MHz; the spec allows 400 kHz
 * during identification). Blocks are 512 bytes; an SDHC card is addressed by block
 * number (32 bits: SDHC and SDXC cards up to 2 TB), a standard-capacity one by byte (at most 2 GB: a block
 * number from 0x800000 up would wrap the 32-bit byte address, so sd_read and sd_write refuse it). CRC is off in SPI mode except for CMD0
 * and CMD8. */
#include "soc.h"

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

    SPI(GPIO_BAUD) = 0xFF;
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
    SPI(GPIO_BAUD) = 1;                  /* 15.6 MHz: the card allows 25 */
    return 0;
}

/* CRC16-CCITT (x^16 + x^12 + x^5 + 1, start 0) of one data byte: what the card appends to a block. */
static uint16_t crc16(uint16_t c, uint8_t b)
{
    c ^= (uint16_t)b << 8;
    for (int i = 0; i < 8; i++)
        c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
    return c;
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
    if (n == 0 || lba + n < lba)
        return 0;
    if (!sd_sdhc && lba + n > 0x800000)
        return 0;
    if (sd_blocks != 0 && sd_blocks != 0xFFFFFFFFu && lba + n > sd_blocks)
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
    for (int i = 0; i < 8 && (r & 0x80); i++)
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
