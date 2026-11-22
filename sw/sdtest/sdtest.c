/* The SD driver's paths, one line each, for the bench to check against what the card (tb/sd_spi_model.v,
 * with its +SD_* faults) was told to do: init, a read of the boot sector, reads at the middle and a block
 * that may be made to fail, a write and its read-back at two places, and requests beyond the disk, which
 * the card must refuse (run with +SD_EXPECT: its error for them is expected). Prints return codes;
 * sdtest/expect-*.txt says what each variant must print. */
#include "soc.h"

extern int printf(const char *, ...);

static uint8_t buf[512], chk[512], ref5[512];

static void pattern(uint32_t lba)
{
    for (int i = 0; i < 512; i++)
        buf[i] = (uint8_t)(i * 3 + lba);
}

static void write_readback(uint32_t lba)
{
    pattern(lba);
    int w = sd_write(lba, buf);
    printf("sdtest: write %u rc=%d\n", (unsigned)lba, w);
    for (int i = 0; i < 512; i++)
        chk[i] = 0;
    int r = sd_read(lba, chk);
    int match = 1;
    for (int i = 0; i < 512; i++)
        if (chk[i] != buf[i])
            match = 0;
    printf("sdtest: readback %u rc=%d match=%d\n", (unsigned)lba, r, match);
}

int main(void)
{
    int rc = sd_init();
    printf("sdtest: init rc=%d sdhc=%d\n", rc, sd_sdhc);
    if (rc)
        return 0;

    rc = sd_read(0, chk);
    printf("sdtest: read 0 rc=%d b0=%02x b510=%02x b511=%02x\n", rc, chk[0], chk[510], chk[511]);
    printf("sdtest: read 4095 rc=%d\n", sd_read(4095, chk));
    printf("sdtest: read 123 rc=%d\n", sd_read(123, chk));
    sd_read(5, ref5);                            /* to see later that a high block did not land here */
    write_readback(5000);
    write_readback(8191);                        /* the last block */
    printf("sdtest: capacity %u blocks\n", (unsigned)sd_blocks);
    if (sd_blocks > 8192) {
        /* a card bigger than the disk image: block numbers past 2 GB (0x400000) and 4 GB (0x800000), the last
         * block, and the first one beyond it */
        rc = sd_read(4194304, chk);           /* the formula image, not block 0 of the disk (b0 would be eb) */
        printf("sdtest: read 4194304 rc=%d b0=%02x b1=%02x\n", rc, chk[0], chk[1]);
        write_readback(0x400005);
        write_readback(0x800005);
        write_readback(sd_blocks - 1);
        sd_read(5, chk);
        int same = 1;
        for (int i = 0; i < 512; i++)
            if (chk[i] != ref5[i])
                same = 0;
        printf("sdtest: block 5 unchanged=%d\n", same);   /* no address bit was dropped */
        rc = sd_read(sd_blocks - 1, chk);
        printf("sdtest: read last rc=%d b0=%02x\n", rc, chk[0]);
        if (sd_blocks != 0xFFFFFFFFu)
            printf("sdtest: read beyond rc=%d\n", sd_read(sd_blocks, chk));
    } else if (!sd_sdhc) {
        printf("sdtest: sdsc read 8388608 rc=%d\n", sd_read(0x800000, chk));   /* the byte address would wrap */
        printf("sdtest: sdsc write 8388608 rc=%d\n", sd_write(0x800000, buf));
    }
    if (sd_blocks <= 8192) {                    /* the disk is the card: 8192 is beyond it, refused */
        printf("sdtest: read 8192 rc=%d\n", sd_read(8192, chk));
        printf("sdtest: write 8192 rc=%d\n", sd_write(8192, buf));
    }
    printf("sdtest: done\n");
    return 0;
}
