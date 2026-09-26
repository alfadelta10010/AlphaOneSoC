/* Linker script for AlphaOneSoC programs. The SoC always boots from flash.
 *
 *   0x2000_0000 – 0x20FF_FFFF : flash (16 MB, read + execute, QSPI CS0)
 *                               reset vector, code, read-only data, and the
 *                               initial image of .data
 *   0x8000_0000 – 0x80FF_FFFF : PSRAM (16 MB, QSPI CS1 / CS2)
 *                               .data, .bss, stack
 *
 * Link with boot_flash.S, which runs first (_boot_start is at the reset
 * vector): it copies .data from its load address in flash to PSRAM, clears
 * .bss, sets sp to _stack_top and jumps to _start. Flash cannot be written
 * (the core faults every store to it), so anything a program writes has to
 * be in PSRAM.
 *
 * link.ld is for the verification flow only, which starts the core straight
 * in PSRAM at 0x8000_0000.
 */
OUTPUT_ARCH("riscv")
ENTRY(_boot_start)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x20000000, LENGTH = 16M
    RAM   (rwx) : ORIGIN = 0x80000000, LENGTH = 16M
}

SECTIONS
{
    .text.init : {
        *(.text.init)
    } > FLASH

    .text : {
        *(.text)
        *(.text.*)
    } > FLASH

    .rodata : {
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
    } > FLASH

    .tohost (NOLOAD) : ALIGN(0x1000) {
        *(.tohost)
    } > RAM

    .data : ALIGN(4) {
        _data_start = .;
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
        . = ALIGN(4);
        _data_end = .;
    } > RAM AT > FLASH
    _data_load = LOADADDR(.data);

    .bss (NOLOAD) : ALIGN(4) {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM

    _end = .;

    /* Stack at the top of PSRAM, 16-byte aligned. */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM) - 16;
}
