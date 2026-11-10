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

int main(void)
{
    FRESULT r;
    UINT n;
    FIL f;
    DIR d;
    FILINFO fi;

    printf("FatFs R%d on the SD card\n", FF_DEFINED);
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

    CHECK(f_mount(0, "", 0));
    printf("PASS\n");
    return 0;
}
