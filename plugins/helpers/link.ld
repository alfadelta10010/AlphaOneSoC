/* Linker script for FyraCore river_core verification.
 *
 * Verification runs the core with RESET_PC = 0x8000_0000 so the flow can share
 * Spike's default DRAM base and riscv-tests' linker conventions. tb/memory_model.v
 * masks addresses to [24:0], so 0x8000_0000 aliases onto the first byte of the
 * 32 MB simulated array and the whole image must fit inside that window.
 *
 * Everything is placed contiguously from 0x8000_0000 with no separate load
 * address: the DUT is loaded from a flat objcopy hex (which is shifted down by
 * 0x8000_0000), and Spike loads the ELF by program header, so a split VMA/LMA
 * would need a copy loop that neither path runs.
 *
 * The hardware memory map (flash at 0x0, RAM at 0x0100_0000) lives in
 * link_soc.ld and is not used by the verification flow.
 */
OUTPUT_ARCH("riscv")
ENTRY(_boot_start)

MEMORY
{
    /* Must not exceed tb/memory_model.v MEM_SIZE (32 MB). */
    MEM (rwx) : ORIGIN = 0x80000000, LENGTH = 32M
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
