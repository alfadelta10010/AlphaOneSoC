#include <zephyr/arch/cpu.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/poweroff.h>
#include <zephyr/sys/sys_io.h>

#define SYSCON_FINISH 0x10020000u

void sys_arch_reboot(int type)
{
	ARG_UNUSED(type);
	sys_write32(0x7777, SYSCON_FINISH);
	for (;;) {
	}
}

void z_sys_poweroff(void)
{
	sys_write32(0x5555, SYSCON_FINISH);
	CODE_UNREACHABLE;
}
