/* Linker script for FyraCore river_core verification
 *
 * FyraCore memory map:
 *   0x0000_0000 – 0x00FF_FFFF : Flash (16 MB) — code
 *   0x0100_0000 – 0x01FF_FFFF : RAM   (16 MB) — data, stack
 *   0x0200_0000 – 0x0200_BFFF : CLINT
 *
 * riscv-tests and most generators expect code at a fixed base address.
 * This script places code at 0x0 (FyraCore reset vector) and data in RAM.
 */
OUTPUT_ARCH("riscv")
ENTRY(_boot_start)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 16M
    RAM   (rwx) : ORIGIN = 0x01000000, LENGTH = 16M
}

SECTIONS
{
    . = 0x00000000;

    .text.init : {
        *(.text.init)
    } > FLASH

    . = ALIGN(0x1000);

    .tohost : {
        *(.tohost)
    } > FLASH

    . = ALIGN(0x1000);

    .text : {
        *(.text)
        *(.text.*)
    } > FLASH

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > FLASH

    . = ALIGN(0x1000);

    .data : {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > RAM AT > FLASH

    .bss : {
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
    } > RAM AT > FLASH

    _end = .;

    /* Stack at top of RAM */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM) - 16;
}
