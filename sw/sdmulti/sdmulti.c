/* The SD driver's multiple-block transfers (CMD18 + CMD12, CMD25 + stop token) against the card model: a
 * read of 8 blocks must equal 8 single reads, 6 blocks written in one transfer must read back by single reads
 * and by one multiple read, a transfer that leaves the card or wraps the block number is refused before any
 * command, and the single-block paths still work afterwards (the card is back in the transfer state).
 * sdmulti/expect-*.txt says what each variant must print. */
#include "soc.h"

extern int printf(const char *, ...);

static uint8_t a[8 * 512], b[8 * 512], one[512];

static int same(const uint8_t *x, const uint8_t *y, int n)
{
    for (int i = 0; i < n; i++)
        if (x[i] != y[i])
            return 0;
    return 1;
}

/* n single reads from lba into out */
static int singles(uint32_t lba, uint8_t *out, int n)
{
    for (int i = 0; i < n; i++) {
        int rc = sd_read(lba + i, out + 512 * i);
        if (rc)
            return rc;
    }
    return 0;
}

static void multi_at(uint32_t lba)
{
    int rc = sd_read_blocks(lba, a, 8);
    int rs = singles(lba, b, 8);
    printf("sdmulti: read x8 at %u rc=%d singles rc=%d same=%d\n", (unsigned)lba, rc, rs, same(a, b, 8 * 512));
}

int main(void)
{
    int rc = sd_init();
    printf("sdmulti: init rc=%d sdhc=%d\n", rc, sd_sdhc);
    if (rc)
        return 0;
    multi_at(0);
    multi_at(4000);
    for (int i = 0; i < 6 * 512; i++)
        a[i] = (uint8_t)(i * 5 + (i >> 9) * 17 + 1);
    printf("sdmulti: write x6 at 200 rc=%d\n", sd_write_blocks(200, a, 6));
    for (int i = 0; i < 6 * 512; i++)
        b[i] = 0;
    int rs = singles(200, b, 6);
    printf("sdmulti: singles back rc=%d same=%d\n", rs, same(a, b, 6 * 512));
    for (int i = 0; i < 6 * 512; i++)
        b[i] = 0;
    int rm = sd_read_blocks(200, b, 6);
    printf("sdmulti: multi back rc=%d same=%d\n", rm, same(a, b, 6 * 512));
    printf("sdmulti: read 199 rc=%d, read 206 rc=%d\n", sd_read(199, one), sd_read(206, one));   /* untouched around it */
    printf("sdmulti: write x1 at 300 rc=%d\n", sd_write_blocks(300, a, 1));
    printf("sdmulti: read x1 at 300 rc=%d same=%d\n", sd_read_blocks(300, b, 1), same(a, b, 512));
    printf("sdmulti: n=0 read rc=%d write rc=%d\n", sd_read_blocks(0, b, 0), sd_write_blocks(0, a, 0));
    printf("sdmulti: wrap read rc=%d write rc=%d\n", sd_read_blocks(0xFFFFFFFFu, b, 2), sd_write_blocks(0xFFFFFFFEu, a, 3));
    if (sd_sdhc && sd_blocks <= 8192) {  /* the card is the disk: a transfer past its end is refused */
        printf("sdmulti: past end read rc=%d write rc=%d\n", sd_read_blocks(8190, b, 4), sd_write_blocks(8190, a, 4));
        printf("sdmulti: to the last block read rc=%d\n", sd_read_blocks(8184, b, 8));
    } else if (sd_sdhc) {                /* a big card: across 2 GB (block 0x400000) and 4 GB (0x800000), and past the end */
        printf("sdmulti: past end read rc=%d write rc=%d\n", sd_read_blocks(sd_blocks - 2, b, 4), sd_write_blocks(sd_blocks - 2, a, 4));
        uint32_t at[2] = {0x3FFFFEu, 0x7FFFFEu};
        for (int k = 0; k < 2; k++) {
            int w = sd_write_blocks(at[k], a, 4);
            for (int i = 0; i < 4 * 512; i++)
                b[i] = 0;
            int r = sd_read_blocks(at[k], b, 4);
            printf("sdmulti: x4 at %u write rc=%d read rc=%d same=%d\n", (unsigned)at[k], w, r, same(a, b, 4 * 512));
        }
    }
    if (!sd_sdhc) {                      /* a 4 GB standard-capacity card: block 0x800000 is where lba * 512 wraps */
        printf("sdmulti: to the last block (0x7FFFF8 x8) rc=%d\n", sd_read_blocks(0x7FFFF8u, b, 8));
        printf("sdmulti: past 4 GB (0x7FFFFC x8) read rc=%d write rc=%d\n", sd_read_blocks(0x7FFFFCu, b, 8), sd_write_blocks(0x7FFFFCu, a, 8));
    }
    printf("sdmulti: single after rc=%d\n", sd_read(1, one));
    printf("sdmulti: done\n");
    return 0;
}
