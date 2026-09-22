/* Minimal boot stub for FyraCore river_core verification.
 *
 * Generator plugins link this as boot.bo with --entry="_boot_start", so it runs
 * before the test's own entry point.
 *
 * The stack pointer is taken from _stack_top in the linker script rather than
 * being hardcoded, so the stub needs no edit when the image is linked at a
 * different base (the verification base 0x8000_0000, see link.ld).
 *
 * It is NOT enough for link_soc.ld, the hardware map: that script gives .data
 * a load address in flash and a virtual address in RAM, and nothing here
 * copies it across or zeroes .bss. A real boot path needs both, plus the
 * .tohost section moved out of read-only flash. link_soc.ld is a description
 * of the intended map, not a working boot script.
 */

    .section .text.init
    .globl _boot_start
_boot_start:
    /* Stack pointer = top of RAM, as defined by the active linker script */
    la      sp, _stack_top

    /* Clear mtvec — tests install their own handler */
    csrw    mtvec, zero

    /* Jump to the test entry point */
    j       _start
