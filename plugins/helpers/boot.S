/* Minimal boot stub for FyraCore river_core verification.
 *
 * Generator plugins link this as boot.bo with --entry="_boot_start", so it runs
 * before the test's own entry point.
 *
 * The stack pointer is taken from _stack_top in the linker script rather than
 * being hardcoded, so the stub needs no edit when the image is linked at a
 * different base (the verification base 0x8000_0000, see link.ld).
 *
 * Programs that boot from flash use boot_flash.S with link_soc.ld instead:
 * there .data has to be copied from flash to PSRAM and .bss cleared, which
 * this stub does not do.
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
