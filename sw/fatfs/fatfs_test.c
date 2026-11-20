/* Rung 4: FatFs on the SD card (docs/ROADMAP.md 9.2). Mounts the card the bench
 * gives it (sw/tools/mkdisk.sh builds the image), lists it, reads a short file, a
 * file with a long name and a 16 KB file against a checksum, then writes: creates,
 * grows, appends, renames, makes a directory, deletes. The host checks the card
 * image afterwards (sw/tools/fatfs_check.py), so a write that FatFs thinks it made
 * but the card never saw fails there. Stops with PASS through syscon. */
#include <stdlib.h>
#include <string.h>
#include "ff.h"
#include "soc.h"

extern int printf(const char *, ...);

static FATFS fs;
static uint8_t buf[1024];

#define FAIL(...) do { printf("FAIL: " __VA_ARGS__); printf("\n"); exit(1); } while (0)
#define CHECK(call) do { FRESULT r_ = (call); if (r_) FAIL("%s = %d", #call, (int)r_); } while (0)

static uint8_t pat_data(unsigned i) { return (i * 7 + 3) & 0xFF; }     /* DATA.BIN, mkdisk.sh */
static uint8_t pat_out(unsigned i)  { return (i * 13 + 5) & 0xFF; }    /* OUT.BIN, written here */

#ifdef FULL
/* A small card, filled until it is full: the short write, no free cluster, a new file refused, and
 * everything given back when the file goes. */
static int full_test(void)
{
    FIL f;
    UINT n;
    FATFS *pfs;
    DWORD free0, free1;
    CHECK(f_mount(&fs, "", 1));
    CHECK(f_getfree("", &free0, &pfs));
    printf("small card: %u free clusters of %u sectors\n", (unsigned)free0, (unsigned)fs.csize);
    CHECK(f_open(&f, "FILL.BIN", FA_CREATE_ALWAYS | FA_WRITE));
    unsigned total = 0;
    for (;;) {
        for (unsigned i = 0; i < 512; i++)
            buf[i] = pat_out(total + i);
        FRESULT r = f_write(&f, buf, 512, &n);
        if (r)
            FAIL("f_write = %d at %u", (int)r, total);
        total += n;
        if (n < 512)
            break;                                  /* full: a short write, not an error */
    }
    CHECK(f_close(&f));
    printf("filled: %u bytes written\n", total);
    CHECK(f_getfree("", &free1, &pfs));
    if (free1 != 0)
        FAIL("%u clusters still free after filling", (unsigned)free1);
    if (total > free0 * fs.csize * 512 || total < (free0 - 1) * fs.csize * 512)
        FAIL("%u bytes written into %u free clusters", total, (unsigned)free0);
    FRESULT r = f_open(&f, "MORE.BIN", FA_CREATE_NEW | FA_WRITE);
    if (r == FR_OK) {                               /* the directory entry fits, its data cannot */
        r = f_write(&f, buf, 512, &n);
        if (r == FR_OK && n)
            FAIL("wrote into a full card");
        f_close(&f);
        f_unlink("MORE.BIN");
    }
    CHECK(f_open(&f, "FILL.BIN", FA_READ));
    for (unsigned off = 0; off < total;) {
        CHECK(f_read(&f, buf, 512, &n));
        if (!n)
            FAIL("FILL.BIN ends at %u of %u", off, total);
        for (UINT i = 0; i < n; i++)
            if (buf[i] != pat_out(off + i))
                FAIL("FILL.BIN byte %u", off + i);
        off += n;
    }
    CHECK(f_close(&f));
    CHECK(f_unlink("FILL.BIN"));
    CHECK(f_getfree("", &free1, &pfs));
    if (free1 != free0)
        FAIL("%u free clusters after the delete, want %u", (unsigned)free1, (unsigned)free0);
    printf("full card ok\n");
    CHECK(f_mount(0, "", 0));
    printf("PASS\n");
    return 0;
}
#endif

int main(void)
{
    FRESULT r;
    UINT n;
    FIL f;
    DIR d;
    FILINFO fi;

    printf("FatFs R%d on the SD card\n", FF_DEFINED);
#ifdef FULL
    return full_test();
#endif
    r = f_mount(&fs, "", 1);
    if (r)
        FAIL("f_mount = %d", (int)r);
    const char *t = fs.fs_type == FS_FAT12 ? "FAT12" : fs.fs_type == FS_FAT16 ? "FAT16" : "FAT32";
    char label[34];
    DWORD vsn;
    CHECK(f_getlabel("", label, &vsn));
    printf("mounted %s, label %s, %u sectors per cluster\n", t, label, (unsigned)fs.csize);
    DWORD nfree;
    FATFS *pfs;
    CHECK(f_getfree("", &nfree, &pfs));
    printf("%u free clusters\n", (unsigned)nfree);

    /* the root directory */
    CHECK(f_opendir(&d, "/"));
    while (f_readdir(&d, &fi) == FR_OK && fi.fname[0])
        printf("  %-24s %7u %s\n", fi.fname, (unsigned)fi.fsize, (fi.fattrib & AM_DIR) ? "<DIR>" : "");
    CHECK(f_closedir(&d));

    /* a short file */
    CHECK(f_open(&f, "HELLO.TXT", FA_READ));
    CHECK(f_read(&f, buf, sizeof buf - 1, &n));
    buf[n] = 0;
    CHECK(f_close(&f));
    printf("HELLO.TXT: %s", (char *)buf);
    if (strncmp((char *)buf, "Hello from the SD card", 22))
        FAIL("HELLO.TXT content");

    /* a long name, in a directory, with a relative path */
    CHECK(f_chdir("SUB"));
    CHECK(f_open(&f, "A long file name.txt", FA_READ));
    CHECK(f_read(&f, buf, sizeof buf - 1, &n));
    buf[n] = 0;
    CHECK(f_close(&f));
    printf("SUB/A long file name.txt: %s", (char *)buf);
    if (strncmp((char *)buf, "long names work", 15))
        FAIL("long name content");
    CHECK(f_chdir("/"));

    /* 16 KB read in 1 KB pieces, against the pattern */
    CHECK(f_open(&f, "DATA.BIN", FA_READ));
    if (f_size(&f) != 16384)
        FAIL("DATA.BIN size %u", (unsigned)f_size(&f));
    unsigned off = 0, sum = 0;
    for (;;) {
        CHECK(f_read(&f, buf, sizeof buf, &n));
        if (!n)
            break;
        for (UINT i = 0; i < n; i++, off++) {
            if (buf[i] != pat_data(off))
                FAIL("DATA.BIN byte %u is %02x, want %02x", off, buf[i], pat_data(off));
            sum += buf[i];
        }
    }
    CHECK(f_close(&f));
    printf("DATA.BIN: %u bytes, sum %u\n", off, sum);

    /* a seek into the middle */
    CHECK(f_open(&f, "DATA.BIN", FA_READ));
    CHECK(f_lseek(&f, 9000));
    CHECK(f_read(&f, buf, 8, &n));
    CHECK(f_close(&f));
    for (UINT i = 0; i < 8; i++)
        if (n != 8 || buf[i] != pat_data(9000 + i))
            FAIL("seek read at 9000");
    printf("seek to 9000 ok\n");

    /* create a file, 3000 bytes in three writes, and read it back */
    CHECK(f_open(&f, "OUT.BIN", FA_CREATE_ALWAYS | FA_WRITE));
    for (int piece = 0; piece < 3; piece++) {
        for (unsigned i = 0; i < 1000; i++)
            buf[i] = pat_out(piece * 1000 + i);
        CHECK(f_write(&f, buf, 1000, &n));
        if (n != 1000)
            FAIL("short write");
    }
    CHECK(f_close(&f));
    CHECK(f_open(&f, "OUT.BIN", FA_READ));
    off = 0;
    for (;;) {
        CHECK(f_read(&f, buf, sizeof buf, &n));
        if (!n)
            break;
        for (UINT i = 0; i < n; i++, off++)
            if (buf[i] != pat_out(off))
                FAIL("OUT.BIN read-back byte %u", off);
    }
    CHECK(f_close(&f));
    if (off != 3000)
        FAIL("OUT.BIN is %u bytes", off);
    printf("OUT.BIN: 3000 bytes written and read back\n");

    /* append to a file that exists, make a directory, write a text file there */
    CHECK(f_open(&f, "APPEND.TXT", FA_WRITE | FA_OPEN_ALWAYS));
    CHECK(f_lseek(&f, f_size(&f)));
    CHECK(f_write(&f, "second line\n", 12, &n));
    CHECK(f_close(&f));
    CHECK(f_mkdir("NEW"));
    CHECK(f_open(&f, "NEW/LOG.TXT", FA_CREATE_NEW | FA_WRITE));
    if (f_printf(&f, "boot %d, %s\n", 42, "ok") < 0)
        FAIL("f_printf");
    CHECK(f_close(&f));

    /* rename and delete */
    CHECK(f_rename("OUT.BIN", "RENAMED.BIN"));
    CHECK(f_unlink("TRASH.TXT"));
    r = f_stat("TRASH.TXT", &fi);
    if (r != FR_NO_FILE)
        FAIL("TRASH.TXT still there (%d)", (int)r);

    /* edge cases: errors FatFs must give, names, empty and truncated files, sizes at a cluster boundary */
#define EXPECT(call, want) do { FRESULT r_ = (call); if (r_ != (want)) FAIL("%s = %d, want %s", #call, (int)r_, #want); } while (0)
    EXPECT(f_open(&f, "NOSUCH.TXT", FA_READ), FR_NO_FILE);
    EXPECT(f_open(&f, "NODIR/X.TXT", FA_WRITE | FA_CREATE_NEW), FR_NO_PATH);
    EXPECT(f_open(&f, "SUB", FA_READ), FR_NO_FILE);                    /* a directory is not a file */
    EXPECT(f_mkdir("SUB"), FR_EXIST);
    EXPECT(f_rename("HELLO.TXT", "DATA.BIN"), FR_EXIST);
    EXPECT(f_unlink("SUB"), FR_DENIED);                                 /* not empty */
    EXPECT(f_unlink("NOSUCH.TXT"), FR_NO_FILE);
    EXPECT(f_open(&f, "OUT.BIN", FA_WRITE | FA_CREATE_NEW), FR_OK);     /* OUT.BIN was renamed away */
    CHECK(f_close(&f));
    EXPECT(f_open(&f, "OUT.BIN", FA_WRITE | FA_CREATE_NEW), FR_EXIST);
    CHECK(f_unlink("OUT.BIN"));
    CHECK(f_open(&f, "hello.txt", FA_READ));                            /* names ignore case */
    CHECK(f_close(&f));

    CHECK(f_open(&f, "EMPTY.TXT", FA_CREATE_ALWAYS | FA_WRITE));        /* an empty file, read to its end */
    CHECK(f_write(&f, buf, 0, &n));
    if (n)
        FAIL("a zero-length write wrote %u", (unsigned)n);
    CHECK(f_close(&f));
    CHECK(f_stat("EMPTY.TXT", &fi));
    if (fi.fsize)
        FAIL("EMPTY.TXT is %u bytes", (unsigned)fi.fsize);
    CHECK(f_open(&f, "EMPTY.TXT", FA_READ));
    CHECK(f_read(&f, buf, 16, &n));
    if (n)
        FAIL("read %u bytes of an empty file", (unsigned)n);
    CHECK(f_close(&f));

    /* a 120-character name */
    char longname[130];
    memset(longname, 'n', 120);
    strcpy(longname + 120, ".txt");
    CHECK(f_open(&f, longname, FA_CREATE_NEW | FA_WRITE));
    CHECK(f_close(&f));
    CHECK(f_stat(longname, &fi));
    if (strcmp(fi.fname, longname))
        FAIL("the long name came back as %s", fi.fname);
    CHECK(f_unlink(longname));

    /* sizes at a cluster boundary, then a truncate and a seek past the end */
    unsigned cl = (unsigned)fs.csize * 512;
    static const int deltas[] = {-1, 0, 1};
    for (unsigned k = 0; k < 3; k++) {
        unsigned len = 2 * cl + deltas[k];
        CHECK(f_open(&f, "EDGE.BIN", FA_CREATE_ALWAYS | FA_WRITE));
        for (unsigned off2 = 0; off2 < len;) {
            unsigned c = len - off2 < 512 ? len - off2 : 512;
            for (unsigned i = 0; i < c; i++)
                buf[i] = pat_out(off2 + i);
            CHECK(f_write(&f, buf, c, &n));
            if (n != c)
                FAIL("short write at %u", off2);
            off2 += c;
        }
        CHECK(f_close(&f));
        CHECK(f_open(&f, "EDGE.BIN", FA_READ));
        if (f_size(&f) != len)
            FAIL("EDGE.BIN is %u, want %u", (unsigned)f_size(&f), len);
        for (unsigned off2 = 0; off2 < len;) {
            CHECK(f_read(&f, buf, 512, &n));
            if (!n)
                FAIL("EDGE.BIN ends at %u of %u", off2, len);
            for (UINT i = 0; i < n; i++)
                if (buf[i] != pat_out(off2 + i))
                    FAIL("EDGE.BIN byte %u", off2 + i);
            off2 += n;
        }
        CHECK(f_lseek(&f, len + 1000));                                 /* read-only: stops at the end */
        if (f_tell(&f) != len)
            FAIL("a seek past the end went to %u", (unsigned)f_tell(&f));
        CHECK(f_read(&f, buf, 8, &n));
        if (n)
            FAIL("read %u bytes at the end", (unsigned)n);
        CHECK(f_close(&f));
    }
    CHECK(f_open(&f, "EDGE.BIN", FA_READ | FA_WRITE));                  /* the last one, 2 clusters + 1 */
    CHECK(f_lseek(&f, 700));
    CHECK(f_truncate(&f));
    CHECK(f_close(&f));
    CHECK(f_stat("EDGE.BIN", &fi));
    if (fi.fsize != 700)
        FAIL("truncated to %u, want 700", (unsigned)fi.fsize);
    CHECK(f_unlink("EDGE.BIN"));
    DWORD nfree2;
    CHECK(f_getfree("", &nfree2, &pfs));
    printf("edge cases ok, %u free clusters\n", (unsigned)nfree2);

    CHECK(f_mount(0, "", 0));
    printf("PASS\n");
    return 0;
}
