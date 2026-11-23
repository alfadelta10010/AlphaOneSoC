#!/usr/bin/env python3
"""Patch a NuttX 12.11.0 tree for AlphaOneSoC (argument: the nuttx directory)."""
import sys, re
root = sys.argv[1]
def edit(path, old, new, count=1):
    p = f"{root}/{path}"; s = open(p).read()
    if new in s: return
    assert old in s, (path, old)
    open(p, "w").write(s.replace(old, new, count))
A = "arch/risc-v/src/qemu-rv"
# poweroff -> syscon FINISH
edit(f"{A}/hardware/qemu_rv_memorymap.h", "#define   QEMU_RV_RESET_BASE   0x100000", "#define   QEMU_RV_RESET_BASE   0x10020000")
# no PLIC on this SoC
edit(f"{A}/qemu_rv_irq.c", "  putreg32(0x0, QEMU_RV_PLIC_ENABLE1);\n  putreg32(0x0, QEMU_RV_PLIC_ENABLE2);\n#else",
      "  /* AlphaOneSoC: no PLIC */\n#else")
edit(f"{A}/qemu_rv_irq.c", "  for (id = 1; id <= 52; id++)\n    {\n      putreg32(1, (uintptr_t)(QEMU_RV_PLIC_PRIORITY + 4 * id));\n    }\n\n  /* Set irq threshold to 0 (permits all global interrupts) */\n\n  putreg32(0, QEMU_RV_PLIC_THRESHOLD);\n",
      "  UNUSED(id);\n")
# 62.5 MHz timebase
edit(f"{A}/qemu_rv_timerisr.c", "#define MTIMER_FREQ 10000000\n#define TICK_COUNT (10000000 / TICK_PER_SEC)",
      "#define MTIMER_FREQ 62500000\n#define TICK_COUNT (62500000 / TICK_PER_SEC)")
# polled UART
edit(f"{A}/Make.defs", "CHIP_CSRCS += qemu_rv_timerisr.c qemu_rv_allocateheap.c", "CHIP_CSRCS += qemu_rv_timerisr.c qemu_rv_allocateheap.c qemu_rv_alphauart.c")
edit(f"{A}/qemu_rv_start.c", "#ifdef CONFIG_16550_UART\n  u16550_earlyserialinit();\n#endif", "#ifdef CONFIG_16550_UART\n  u16550_earlyserialinit();\n#else\n  alpha_uart_earlyinit();\n#endif")
edit(f"{A}/qemu_rv_start.c", "#ifdef CONFIG_16550_UART\n  u16550_serialinit();\n#endif", "#ifdef CONFIG_16550_UART\n  u16550_serialinit();\n#else\n  alpha_uart_init();\n#endif")
edit(f"{A}/qemu_rv_start.c", "void riscv_earlyserialinit(void)", "void alpha_uart_earlyinit(void);\nvoid alpha_uart_init(void);\n\nvoid riscv_earlyserialinit(void)")
