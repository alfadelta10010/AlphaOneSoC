/* Linker script for FyraCore simulation tests
 *
 * Unified memory map:
 *   0x0000_0000 – 0x00FF_FFFF : Flash (16 MB) — .text, .rodata
 *   0x0100_0000 – 0x01FF_FFFF : RAM   (16 MB) — .data, .bss, stack
 *
 * For small unit tests that fit entirely in Flash, .data and stack can
 * also live in Flash (simplest case, used by default here).
 * For Linux boot, use a separate linker script with .data at 0x01000000.
 */
ENTRY(_start)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 16M
    RAM   (rwx) : ORIGIN = 0x01000000, LENGTH = 16M
}

SECTIONS
{
    .text 0x00000000 :
    {
        *(.text.init)
        *(.text*)
    } > FLASH

    .rodata :
    {
        *(.rodata*)
    } > FLASH

    /* Small tests keep .data in Flash for simplicity */
    .data :
    {
        *(.data*)
        *(.sdata*)
    } > FLASH

    .bss :
    {
        *(.bss*)
        *(.sbss*)
    } > FLASH

    /* Stack at end of first 64KB (safe for small tests) */
    _stack_top = 0x0000FFF0;
}
