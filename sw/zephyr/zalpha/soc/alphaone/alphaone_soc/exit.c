/* The run ends through the syscon FINISH register when main returns or the kernel hits a fatal error:
 * 0x5555 = pass, (code << 16) | 0x3333 = fail. The bench stops on it. Note: ztest's main returns 0 even
 * when a test fails, so a ztest run is judged by run-zephyr.sh (it also rejects any FAIL line). */
#include <stdint.h>
#include <zephyr/kernel.h>
#include <zephyr/fatal.h>

#define SYSCON_FINISH ((volatile uint32_t *)0x10020000u)

extern int __real_main(void);

int __wrap_main(void)
{
	int rc = __real_main();

	*SYSCON_FINISH = (rc == 0) ? 0x5555u : (((uint32_t)rc & 0xFFFFu) << 16) | 0x3333u;
	for (;;) {
	}
}

/* A fatal error (a fault, an oops, a failed assert) ends the run as a failure instead of spinning in
 * arch_system_halt until the cycle cap: code 0x7F, the reason in the low byte of the log line above. */
void k_sys_fatal_error_handler(unsigned int reason, const struct arch_esf *esf)
{
	ARG_UNUSED(esf);
	printk("FATAL: k_sys_fatal_error_handler reason %u\n", reason);
	*SYSCON_FINISH = (0x7Fu << 16) | 0x3333u;
	for (;;) {
	}
}
