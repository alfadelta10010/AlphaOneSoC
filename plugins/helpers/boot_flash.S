/* Boot stub for AlphaOneSoC programs, linked with link_soc.ld. The SoC always
 * boots from flash.
 *
 * The core starts at 0x2000_0000, the first byte of flash, which is where
 * link_soc.ld puts .text.init. Nothing here is fixed in silicon: this is
 * ordinary code in flash, and whatever was last programmed there runs
 * instead.
 *
 * It does what a C runtime needs before _start:
 *   - copy .data from its load address in flash to PSRAM,
 *   - clear .bss,
 *   - set sp to the top of PSRAM,
 * and leaves mtvec at 0, so a program installs its own trap handler before
 * it can take a trap. Word copies: link_soc.ld aligns both sections to 4.
 */

    .section .text.init
    .globl _boot_start
_boot_start:
    la      t0, _data_load
    la      t1, _data_start
    la      t2, _data_end
1:  bgeu    t1, t2, 2f
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       1b

2:  la      t1, _bss_start
    la      t2, _bss_end
3:  bgeu    t1, t2, 4f
    sw      zero, 0(t1)
    addi    t1, t1, 4
    j       3b

4:  la      sp, _stack_top
    csrw    mtvec, zero
    j       _start
