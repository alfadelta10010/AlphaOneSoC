/* The run ends through the syscon FINISH register when main returns or the kernel halts after a fatal error:
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

/* A fatal error ends the run as a failure instead of spinning until the cycle cap: the default
 * k_sys_fatal_error_handler and k_fatal_halt both end in arch_system_halt (a weak function in
 * kernel/fatal.c). Not k_sys_fatal_error_handler itself: many tests define their own, and tests that
 * recover from a fault never reach this. Code 0x7F. */
FUNC_NORETURN void arch_system_halt(unsigned int reason)
{
	ARG_UNUSED(reason);
	*SYSCON_FINISH = (0x7Fu << 16) | 0x3333u;
	for (;;) {
	}
}
