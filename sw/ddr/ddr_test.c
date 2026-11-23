/* A payload that checks what the loader's boot-time DDR sweep (loader/ddr.S) left: QSPI_CFG,
 * BOOT_MODE, and that flash reads in the mode the loader chose are right (the image's own
 * flash copy against the PSRAM copy the loader made in SDR). It services the watchdog, as an
 * image with IMAGE_F_DDR must.
 *
 * -DRB, -DDF and -DWD0 build the reboot cases (a marker in PSRAM tells the boots apart): a soft
 * reboot with DDR on (the sweep runs again), BOOT_MODE 0xDF kept across a reboot (it does not),
 * and a watchdog reset whose BOOT_MODE is not a DDR note (the sweep runs again).
 *
 * -DWD builds the watchdog fallback test: on the first boot, with DDR on, it stops servicing
 * the watchdog and sets the shortest timeout; the watchdog resets the SoC, the loader reads
 * BOOT_MODE 0xD8 + k with the WDT cause and keeps the flash in SDR, and the second boot passes. */
#include "soc.h"

extern int printf(const char *, ...);

#define MARK  ((volatile uint32_t *)0x80800000u)   /* PSRAM keeps it across a reboot */
#define MAGIC 0xD0D0CAFEu
#if defined(WD0)
#define WD0_NAME "ddrwd0"
#elif defined(RB)
#define WD0_NAME "ddrrb"
#elif defined(DT)
#define WD0_NAME "ddrdt"
#else
#define WD0_NAME "ddrdf"
#endif

int main(void)
{
    uint32_t cfg = *reg32(SYSCON_BASE + SYSCON_QSPI_CFG) & 0x1F;
    uint32_t mode = *reg8(SYSCON_BASE + SYSCON_BOOT_MODE);
    int ddr = (cfg >> 1) & 1;
    printf("ddr: QSPI_CFG %02x (STREAM %u, DDR %u, DDR_CAP %u), BOOT_MODE %02x\n", (unsigned)cfg,
           (unsigned)(cfg & 1), (unsigned)ddr, (unsigned)(cfg >> 2), (unsigned)mode);

#if defined(WD)
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
#elif defined(WD0) || defined(RB) || defined(DF) || defined(DT)
    /* Two boots, told apart by a marker in PSRAM, which a reboot does not clear. */
    const char *name = WD0_NAME;
    if (*MARK == MAGIC) {
        *MARK = 0;
#if defined(DF) || defined(DT)
        printf("%s: second boot, SDR kept\n", name);
        return ddr ? 1 : 0;                         /* BOOT_MODE 0xDF kept the flash in SDR */
#else
        printf("%s: second boot, DDR on again\n", name);
        return (ddr && (mode - BOOT_DDR_TRIED) < 8) ? 0 : 1;   /* a fresh sweep */
#endif
    }
    if (!ddr || (mode - BOOT_DDR_TRIED) >= 8) {
        printf("FAIL: the first boot is not in DDR\n");
        return 1;
    }
    *MARK = MAGIC;
    uart_flush();
#if defined(DT)
    /* A trap with DDR on: the loader's trap handler must spin, so the watchdog (TOP 1 here, to be quick) resets. */
    printf("%s: first boot, an illegal instruction with DDR on\n", name);
    uart_flush();
    *reg32(SYSCON_BASE + SYSCON_WDT_TORR) = 1;
    __asm__ volatile(".word 0x00000000");
    for (;;)
        ;
#elif defined(WD0)
    /* A watchdog reset whose BOOT_MODE is not a DDR note: the loader must sweep again. */
    *reg8(SYSCON_BASE + SYSCON_BOOT_MODE) = 0x00;
    printf("%s: first boot, BOOT_MODE cleared, now not servicing the watchdog\n", name);
    uart_flush();
    *reg32(SYSCON_BASE + SYSCON_WDT_TORR) = 1;
    for (;;)
        ;
#else
#if defined(DF)
    *reg8(SYSCON_BASE + SYSCON_BOOT_MODE) = BOOT_DDR_FAILED;
    printf("%s: first boot, BOOT_MODE set to DF, rebooting\n", name);
#else
    printf("%s: first boot, rebooting through syscon\n", name);
#endif
    uart_flush();
    *reg32(SYSCON_BASE + SYSCON_FINISH) = FINISH_REBOOT;
    for (;;)
        ;
#endif
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
