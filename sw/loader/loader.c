/* Flash loader. Runs in place from flash after reset (start.S), then:
 *
 *   rule 2   sets the UART divisor and prints a banner
 *   rule 3   reads RESET_CAUSE and BOOT_MODE, prints them, and clears
 *            RESET_CAUSE so the next boot sees only its own cause
 *   -        finds the image header at flash offset IMAGE_FLASH_OFF, checks
 *            it, copies the payload to PSRAM, checks the copy's sum
 *   -        fence.i, then jumps to the image's entry with a0 = hartid 0 and
 *            a1 = 0 (no device tree yet)
 *
 * Rules 4 and 5 (SPI enable, SD init) belong to the code that uses the SPI;
 * the loader leaves the SPI controller disabled. Rule 6: the watchdog is not
 * touched. Rule 1 (mtvec) is in start.S.
 *
 * Failures print one line and stop through syscon FINISH with a code:
 *   1 bad magic, 2 payload does not fit PSRAM, 3 entry outside the payload,
 *   4 sum mismatch after the copy.
 */
#include "soc.h"

#define LOAD_LIMIT (PSRAM_BASE + PSRAM_SIZE - 0x10000u)   /* the top 64 KB are the stack */

static void fail(unsigned code, const char *why)
{
    uart_puts("loader: ");
    uart_puts(why);
    uart_puts("\n");
    soc_fail(code);
}

static void print_kv(const char *k, uint32_t v, int digits)
{
    uart_puts(k);
    uart_puts("0x");
    uart_puthex(v, digits);
}

void loader_main(void)
{
    uart_init(UART_DIVISOR);
    uart_puts("\nAlphaOne loader\n");

    uint32_t cause = *reg8(SYSCON_BASE + SYSCON_RESET_CAUSE);
    uint32_t mode  = *reg8(SYSCON_BASE + SYSCON_BOOT_MODE);
    *reg8(SYSCON_BASE + SYSCON_RESET_CAUSE) = 0x7;
    print_kv("chip id ", *reg32(SYSCON_BASE + SYSCON_CHIP_ID), 8);
    print_kv("  reset cause ", cause, 2);
    print_kv("  boot mode ", mode, 2);
    uart_puts("\n");

    const struct image_hdr *h = (const struct image_hdr *)(FLASH_BASE + IMAGE_FLASH_OFF);
    const uint32_t *src = (const uint32_t *)(FLASH_BASE + IMAGE_FLASH_OFF + sizeof *h);
    uint32_t magic = h->magic, load = h->load_addr, size = h->size,
             entry = h->entry, want = h->sum;

    if (magic != IMAGE_MAGIC)
        fail(1, "no image (bad magic)");
    if (load < PSRAM_BASE || (load & 3) || (size & 3) || size > LOAD_LIMIT - load)
        fail(2, "image does not fit PSRAM");
    if (entry < load || entry >= load + size)
        fail(3, "entry outside the image");

    print_kv("image ", size, 8);
    print_kv(" bytes -> ", load, 8);
    uart_puts("\n");

    volatile uint32_t *dst = (volatile uint32_t *)load;
    uint32_t sum = 0;
    for (uint32_t i = 0; i < size / 4; i++)
        dst[i] = src[i];
    for (uint32_t i = 0; i < size / 4; i++)
        sum += dst[i];
    if (sum != want)
        fail(4, "sum mismatch after the copy");

    print_kv("sum ok, jumping to ", entry, 8);
    uart_puts("\n");
    uart_flush();

    __asm__ volatile("fence.i");
    ((void (*)(unsigned, unsigned))entry)(0, 0);
    for (;;)
        ;
}
