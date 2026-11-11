/* The flash loader: runs in place from the first 64 KB of flash. It has no
 * writable data of its own (its stack is in PSRAM), so there is nothing to
 * copy at start. The image it boots sits at flash offset 0x10000. */
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
    .text : {
        *(.text .text.*)
    } > FLASH
    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > FLASH

    /* Any writable data would be silently lost: keep the loader free of it. */
    .data : { *(.data .data.*) *(.sdata .sdata.*) *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) } > RAM
    ASSERT(SIZEOF(.data) == 0, "the loader must not have writable data or bss")

    _stack_top = ORIGIN(RAM) + LENGTH(RAM) - 16;
}
