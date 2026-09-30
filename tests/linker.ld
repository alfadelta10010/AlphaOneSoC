/* Linker script for FyraCore simulation tests (make asm, tb/tb_cpu.v)
 *
 * Everything is placed in PSRAM at 0x8000_0000, where tb_cpu boots the core
 * and tb/memory_model.v models 16 MB. Flash (0x2000_0000) is read-only, so
 * a test that needs writable data keeps it here too. Programs that boot
 * from flash use plugins/helpers/link_soc.ld instead.
 */
ENTRY(_start)

MEMORY
{
    FLASH (rwx) : ORIGIN = 0x80000000, LENGTH = 16M
}

SECTIONS
{
    .text 0x80000000 :
    {
        *(.text.init)
        *(.text*)
    } > FLASH

    .rodata :
    {
        *(.rodata*)
    } > FLASH

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
    _stack_top = 0x8000FFF0;
}
