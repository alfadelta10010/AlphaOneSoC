/* Linker script for FyraCore river_core verification.
 *
 * Verification boots the core from PSRAM at 0x8000_0000 (boot_addr), which is
 * also Spike's DRAM base and riscv-tests' linker convention. The whole image,
 * data and stack included, lives in the 16 MB of PSRAM tb/memory_model.v
 * models; flash is read-only.
 *
 * Everything is placed contiguously from 0x8000_0000 with no separate load
 * address: the DUT is loaded from a flat objcopy hex (which is shifted down by
 * 0x8000_0000), and Spike loads the ELF by program header, so a split VMA/LMA
 * would need a copy loop that neither path runs.
 *
 * link_soc.ld is the script for programs that boot from flash at 0x2000_0000;
 * the verification flow does not use it.
 */
OUTPUT_ARCH("riscv")
ENTRY(_boot_start)

MEMORY
{
    /* Must not exceed tb/memory_model.v MEM_SIZE (16 MB). */
    MEM (rwx) : ORIGIN = 0x80000000, LENGTH = 16M
}

SECTIONS
{
    . = 0x80000000;

    .text.init : { *(.text.init) } > MEM

    . = ALIGN(0x1000);

    .tohost : { *(.tohost) } > MEM

    . = ALIGN(0x1000);

    .text : {
        *(.text)
        *(.text.*)
    } > MEM

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > MEM

    . = ALIGN(0x1000);

    .data : {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > MEM

    .bss : {
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
    } > MEM

    _end = .;

    /* Stack at the top of the simulated memory, 16-byte aligned. */
    _stack_top = ORIGIN(MEM) + LENGTH(MEM) - 16;
}
