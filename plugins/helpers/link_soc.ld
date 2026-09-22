/* The intended FyraCore hardware memory map. NOT used by the verification
 * flow, which links at 0x8000_0000 with link.ld so Spike can agree about
 * which addresses exist.
 *
 *   0x0000_0000 – 0x00FF_FFFF : Flash (16 MB) — code, XIP from QSPI CS0
 *   0x0100_0000 – 0x01FF_FFFF : RAM   (16 MB) — data, stack (QSPI CS1,
 *                               2x8 MB PSRAM used contiguously)
 *   0x0200_0000 – 0x0200_BFFF : CLINT
 *
 * NOT yet bootable as written: .data is given a load address in flash and a
 * virtual address in RAM, and plugins/helpers/boot.S copies neither it nor
 * clears .bss, so a program linked with this reads uninitialised RAM. .tohost
 * also lands in read-only flash. The map itself is provisional — there is no
 * SoC top level yet, the interconnect may become AHB, and the peripheral set
 * is unsettled.
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
