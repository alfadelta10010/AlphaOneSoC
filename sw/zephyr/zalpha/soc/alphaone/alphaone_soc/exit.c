/* The run ends through the syscon FINISH register when main returns:
 * 0x5555 = pass, (code << 16) | 0x3333 = fail. The bench stops on it. */
#include <stdint.h>

#define SYSCON_FINISH ((volatile uint32_t *)0x10020000u)

extern int __real_main(void);

int __wrap_main(void)
{
	int rc = __real_main();

	*SYSCON_FINISH = (rc == 0) ? 0x5555u : (((uint32_t)rc & 0xFFFFu) << 16) | 0x3333u;
	for (;;) {
	}
}
