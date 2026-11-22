/* A program the loader copies to PSRAM (sw/loader). Text, data and bss all
 * live in PSRAM; the top 64 KB are left for the stack. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 16M - 64K
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : ALIGN(4) {
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
    } > RAM

    .bss (NOLOAD) : ALIGN(4) {
        _bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM

    _end = .;
    _stack_top = 0x80000000 + 16M - 16;
}
