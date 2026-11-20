/* A payload that checks what the loader's boot-time DDR sweep (loader/ddr.S) left: QSPI_CFG,
 * BOOT_MODE, and that flash reads in the mode the loader chose are right (the image's own
 * flash copy against the PSRAM copy the loader made in SDR). It services the watchdog, as an
 * image with IMAGE_F_DDR must.
 *
 * -DWD builds the watchdog fallback test: on the first boot, with DDR on, it stops servicing
 * the watchdog and sets the shortest timeout; the watchdog resets the SoC, the loader reads
 * BOOT_MODE 0xD8 + k with the WDT cause and keeps the flash in SDR, and the second boot passes. */
#include "soc.h"

extern int printf(const char *, ...);

int main(void)
{
    uint32_t cfg = *reg32(SYSCON_BASE + SYSCON_QSPI_CFG) & 0x1F;
    uint32_t mode = *reg8(SYSCON_BASE + SYSCON_BOOT_MODE);
    int ddr = (cfg >> 1) & 1;
    printf("ddr: QSPI_CFG %02x (STREAM %u, DDR %u, DDR_CAP %u), BOOT_MODE %02x\n", (unsigned)cfg,
           (unsigned)(cfg & 1), (unsigned)ddr, (unsigned)(cfg >> 2), (unsigned)mode);

#ifdef WD
    if (mode == BOOT_DDR_FAILED) {
        printf("ddrwd: second boot, the flash is SDR again\n");
        if (ddr)
            return 1;
        return 0;
    }
    if (!ddr || (mode - BOOT_DDR_TRIED) >= 8) {
        printf("FAIL: the first boot is not in DDR\n");
        return 1;
    }
    printf("ddrwd: first boot, DDR on, not servicing the watchdog now\n");
    uart_flush();
    *reg32(SYSCON_BASE + SYSCON_WDT_TORR) = 1;      /* TOP 1: 131,072 to 196,608 clocks, and a kick */
    for (;;)
        ;
#else
    const struct image_hdr *h = (const struct image_hdr *)(FLASH_BASE + IMAGE_FLASH_OFF);
    const volatile uint32_t *fl = (const volatile uint32_t *)(FLASH_BASE + IMAGE_FLASH_OFF + sizeof *h);
    const volatile uint32_t *ps = (const volatile uint32_t *)h->load_addr;
    uint32_t words = h->size / 4, bad = 0;
    for (uint32_t i = 0; i < words; i++) {
        if (fl[i] != ps[i])
            bad++;
        if ((i & 255) == 0)
            wdt_kick();
    }
    printf("ddr: %u words of the image read back from flash in %s, %u differ\n", (unsigned)words,
           ddr ? "DDR" : "SDR", (unsigned)bad);
    if (bad)
        return 1;
    wdt_kick();
    return 0;
#endif
}
