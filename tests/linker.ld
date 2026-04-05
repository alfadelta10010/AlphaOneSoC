/* Linker script for FyraCore simulation tests */
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    .text 0x00000000 :
    {
        *(.text.init)
        *(.text*)
    } > RAM

    .rodata :
    {
        *(.rodata*)
    } > RAM

    .data 0x00000800 :
    {
        *(.data*)
        *(.sdata*)
    } > RAM

    .bss :
    {
        *(.bss*)
        *(.sbss*)
    } > RAM

    /* Stack at top of memory */
    _stack_top = 0x0000FFF0;
}
