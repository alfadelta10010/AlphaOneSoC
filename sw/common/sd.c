/* An SD card in SPI mode on the SPI controller (src/gpio.v), polled.
 * Follows the boot contract (docs/ROADMAP.md 9.1 rules 4 and 5): EN is set with
 * every CS# high, at least 74 clocks go out with CS# high before CMD0, and the
 * card is first clocked at BAUD 0xFF (122 kHz at 62.5 MHz; the spec allows 400 kHz
 * during identification). Blocks are 512 bytes; an SDHC card is addressed by block
 * number, a standard-capacity one by byte. CRC is off in SPI mode except for CMD0
 * and CMD8. */
#include "soc.h"

int sd_sdhc;

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

int sd_init(void)
{
    uint32_t ocr = 0;
    uint8_t r;

    SPI(GPIO_BAUD) = 0xFF;
    cs_high();
    SPI(GPIO_SPICTL) = 1;
    for (int i = 0; i < 10; i++)         /* 80 clocks with CS# high */
        xfer(0xFF);
    cs_low();                            /* a card left in the middle of a block */
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
    if (r == 0x01) {                     /* R7: the voltage and check pattern come back */
        uint32_t v = 0;
        for (int i = 0; i < 4; i++)
            v = (v << 8) | xfer(0xFF);
        if ((v & 0xFFF) != 0x1AA) {
            cs_high();
            return 2;
        }
    }
    cs_high();
    xfer(0xFF);

    for (int i = 0; i < 2000; i++) {     /* ACMD41 until the card leaves idle */
        cs_low();
        r = acmd(41, 0x40000000);
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
    SPI(GPIO_BAUD) = 1;                  /* 15.6 MHz: the card allows 25 */
    return 0;
}

int sd_read(uint32_t lba, void *buf)
{
    uint8_t *p = buf, r;
    cs_low();
    r = cmd(17, sd_sdhc ? lba : lba * 512, 0x01);
    if (r != 0x00) {
        cs_high();
        return 1;
    }
    int t = 0;
    while (xfer(0xFF) != 0xFE)           /* the data token */
        if (++t > 100000) {
            cs_high();
            return 2;
        }
    for (int i = 0; i < 512; i++)
        *p++ = xfer(0xFF);
    xfer(0xFF);                          /* CRC16, unchecked */
    xfer(0xFF);
    cs_high();
    xfer(0xFF);
    return 0;
}

int sd_write(uint32_t lba, const void *buf)
{
    const uint8_t *p = buf;
    uint8_t r;
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
    if ((r & 0x1F) != 0x05) {            /* data accepted */
        cs_high();
        return 2;
    }
    int t = 0;
    while (xfer(0xFF) != 0xFF)           /* busy while the card programs */
        if (++t > 1000000) {
            cs_high();
            return 3;
        }
    cs_high();
    xfer(0xFF);
    return 0;
}
