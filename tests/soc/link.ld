/* SoC peripheral tests: boot from flash, like the chip. Code and constants
 * in flash at 0x2000_0000 (the reset PC); scratch data in PSRAM, which the
 * testbench's QSPI Pmod model zero-fills. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY
{
    FLASH (rx)  : ORIGIN = 0x20000000, LENGTH = 64K
    RAM   (rwx) : ORIGIN = 0x80000000, LENGTH = 16M
}
SECTIONS
{
    .text.init : { *(.text.init) } > FLASH
    .text      : { *(.text) *(.text.*) } > FLASH
    .rodata    : { *(.rodata) *(.rodata.*) *(.srodata*) } > FLASH
    .bss (NOLOAD) : { *(.bss) *(.sbss) *(COMMON) } > RAM
}
