/* WO-70 adv_reboot: reboots and a watchdog reset in the middle of PSRAM
 * fetches / line bursts, then a cold boot from flash. tb/tb_adv.v,
 * -DCMODE=0/1/2.
 *
 * Spec basis: docs/soc-architecture.md "Reboot" (the SoC restarts from flash
 * exactly as after a pin reset; RESET_CAUSE SOFT set, PIN kept, BOOT_MODE
 * kept; QSPI_CFG back to its reset value), "Watchdog" (an expiry reboots and
 * sets RESET_CAUSE.WDT; the watchdog is disabled afterwards; a write to mtime
 * that toggles the tapped bit counts as a tick), docs/pins-and-peripherals.md
 * 6 (pins released while held) and 12 (CACHE_CTL resets to 0 on every reset,
 * reads 2 = cache built, EN 0, PBURST 0).
 *
 * Boot n is told by BOOT_MODE (0 at the pin reset):
 *   every boot: CACHE_CTL = 2 and QSPI_CFG = 9 (STREAM = 1 with strap 0, DDR 0,
 *   DDR_CAP 2: soc-architecture.md "syscon" +0x1C) before the program writes
 *   them; RESET_CAUSE as expected (PIN / SOFT / WDT), then W1C; a
 *   64-instruction PSRAM routine (fresh copy, FENCE.I) returns 2016.
 *   boot 0..2: the victim line V (cold, PSRAM) is entered at word 0 and the
 *   FINISH 0x7777 store sits at word n: with the cache on the fill of V
 *   (a burst with PBURST) is still running when the reboot lands at boots 0
 *   and 1 (cued). At boot 2 it is timing whether the fill is still open
 *   (WO-75 measured: CE# already high in c1 and c2), so boot 2 is not cued.
 *   boot 3: the watchdog (TOP 0, reset mode) is made to expire by three
 *   toggles of mtime[14] from PSRAM code followed by cold PSRAM nops.
 *   boot 4: RESET_CAUSE = WDT, WDT_CR = 0, then pass.
 * The bench checks the pins one clock into every reset and that CACHE_CTL
 * is cleared, and, cued with 0xC0 (cache modes only), that the reset cut a
 * PSRAM read. Fail codes: 0x50 + boot (CACHE_CTL), 0x58 (QSPI_CFG), 0x60 +
 * boot (RESET_CAUSE), 0x68 (routine sum), 0x6E (WDT_CR after the reset),
 * 0x6F (the victim fell through).
 */
#include "adv.h"

#define KCODE  0x80030000
#define VICT   0x80020000

    .section .text.init
    .globl _start
_start:
    la   t0, trap
    csrw mtvec, t0
    li   s11, SYSCON
    li   s10, 0
    lbu  s0, BOOT_MODE(s11)       /* s0 = boot number */
    li   t0, CACHE_CTL
    lw   a7, 0(t0)
    addi a6, s0, 0x50
    li   t1, 2
    bne  a7, t1, test_fail
    lw   a7, QSPI_CFG(s11)
    li   a6, 0x58
    li   t1, (1 | (2 << 2))       /* reset value: STREAM 1 (strap 0), DDR 0, DDR_CAP 2 */
    bne  a7, t1, test_fail
    /* expected cause: boot 0 PIN, 1..3 SOFT, 4 WDT */
    li   t1, 1
    beqz s0, 1f
    li   t1, 2
    li   t2, 4
    bne  s0, t2, 1f
    li   t1, 4
1:  lbu  a7, RST_CAUSE(s11)
    addi a6, s0, 0x60
    bne  a7, t1, test_fail
    li   t1, 7
    sb   t1, RST_CAUSE(s11)       /* W1C all */
    li   t0, 4
    bne  s0, t0, 1f
    lw   a7, WDT_CR(s11)
    li   a6, 0x6E
    bnez a7, test_fail
1:  /* cache mode, then the routine */
    li   t0, CACHE_CTL
    li   t1, CCTL_VAL
    sw   t1, 0(t0)
    li   a0, KCODE
    li   t1, 1
2:  slli t2, t1, 20
    li   t3, 0x00050513
    or   t2, t2, t3
    sw   t2, 0(a0)
    addi a0, a0, 4
    addi t1, t1, 1
    li   t3, 64
    blt  t1, t3, 2b
    li   t2, INSN_JR_RA
    sw   t2, 0(a0)
    fence.i
    li   a0, 0
    li   t0, KCODE
    jalr ra, 0(t0)
    mv   a7, a0
    li   a6, 0x68
    li   t1, 2016
    bne  a0, t1, test_fail
    SIGF a0
    li   t0, 4
    beq  s0, t0, done
    li   t0, 3
    beq  s0, t0, wdt_boot
    /* boots 0..2: victim line, FINISH 0x7777 at word s0 */
    li   a0, VICT
    li   t1, 0
3:  li   t2, ADDI_A0(1)
    bne  t1, s0, 4f
    li   t2, 0x00EDA023           /* sw a4, 0(s11) */
4:  sw   t2, 0(a0)
    addi a0, a0, 4
    addi t1, t1, 1
    li   t3, 12
    blt  t1, t3, 3b
    li   t2, 0x0000006F           /* j . */
    sw   t2, 0(a0)
    addi t1, s0, 1
    sb   t1, BOOT_MODE(s11)
    fence.i
#if CMODE != 0
    li   t0, 2                    /* boot 2: the store at word 2 may complete after the fill */
    bgeu s0, t0, 8f               /* has ended (timing, no spec promise): not cued */
    EVENT 0xC0
8:
#endif
    li   a4, FINISH_RESET
    li   t0, VICT
    jr   t0
wdt_boot:
    /* PSRAM: sw zero/t1 x6 to mtime (three rising edges of bit 14), 16 nops, j . */
    li   a0, VICT
    li   t1, 0
5:  andi t2, t1, 1
    li   t3, 0x0002A023           /* sw zero, 0(t0) */
    beqz t2, 6f
    li   t3, 0x0062A023           /* sw t1, 0(t0) */
6:  sw   t3, 0(a0)
    addi a0, a0, 4
    addi t1, t1, 1
    li   t2, 6
    blt  t1, t2, 5b
    li   t1, 0
    li   t3, INSN_NOP
7:  sw   t3, 0(a0)
    addi a0, a0, 4
    addi t1, t1, 1
    li   t2, 40
    blt  t1, t2, 7b
    li   t3, 0x0000006F
    sw   t3, 0(a0)
    li   t1, 4
    sb   t1, BOOT_MODE(s11)
    sw   zero, WDT_TORR(s11)      /* TOP 0 (and a kick) */
    li   t1, 1
    sw   t1, WDT_CR(s11)          /* EN, reset mode */
    fence.i
#if CMODE != 0
    EVENT 0xC0
#endif
    li   t0, MTIME
    li   t1, 0x4000
    li   t2, VICT
    jr   t2
done:
    ADV_PASS

    .balign 4                    /* mtvec BASE is 4-byte aligned: the low bits are its MODE field (WARL) */
trap:
    csrr a7, mcause
    li   a6, 0x7E
    j    test_fail

    ADV_FAIL_BODY
