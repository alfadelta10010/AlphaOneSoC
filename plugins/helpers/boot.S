/* Minimal boot stub for FyraCore river_core verification.
 *
 * The riscv_tests generator plugin links this as boot.bo with
 * --entry="_boot_start". It runs before the test's rvtest_entry_point.
 *
 * FyraCore resets at 0x00000000 — this stub lives at that address.
 * It sets up a stack pointer, clears mtvec (direct mode), and
 * jumps to the test entry point.
 */

    .section .text.init
    .globl _boot_start
_boot_start:
    /* Set stack pointer to top of RAM (0x01000000 + 16MB - 16) */
    lui     sp, 0x01FFF
    addi    sp, sp, 0x7F0       /* sp = 0x01FFF7F0 (near top of RAM) */

    /* Clear mtvec — tests set it themselves */
    csrw    mtvec, zero

    /* Jump to the riscv-tests entry point */
    j       _start
