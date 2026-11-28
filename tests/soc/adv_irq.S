/* WO-70 adv_irq: interrupts against cold PSRAM fills. tb/tb_adv.v,
 * -DCMODE=0/1/2, -DRXDIV=n (UART divisor for phase 1, default 34 = the chip's
 * ratio at 62.5 MHz; 4 = 8.5x the chip's character rate, a stress).
 *
 * Spec basis: docs/soc-architecture.md "Timer and interrupts" (priority MEI >
 * MSI > MTI; WFI wakes on pending and enabled regardless of mstatus.MIE);
 * docs/pins-and-peripherals.md 2 (16550A, RX FIFO 8, trigger codes 1/2/4/7,
 * IID 4 / 0xC), 7 (PLIC: claim = lowest eligible id, clears pending; the
 * gateway forwards a source once and holds it until completed; a level still
 * high at the completion is forwarded again; source 9 = one-clock pulse,
 * sticky pend), the watchdog interrupt mode; WO-69 (GPIO IN_IE/IN_IP, W1C).
 * EXPECTED per phase:
 *   1 64 bytes back to back at line rate (trigger 7) while cold 1 KB PSRAM code
 *     runs: every byte exactly once, in order (fail 0x70 data, 0x72 lost / not
 *     all within the time); every routine pass returns 32896 (0x71); no LSR.OE
 *     at RXDIV 34 (0x73; at RXDIV 4 the overrun is reported, not failed).
 *   2 WFI at a line's last word (next line cold): MIE=0 -> no trap, the code
 *     after WFI runs, a manual claim returns 1 (0x76); MIE=1 -> one MEI trap,
 *     mepc = the WFI + 4 (0x77).
 *   3 PLIC claim/complete racing a new GPIO edge: after every W1C of IN_IP the
 *     bench toggles gpio_in[7] 0..255 clocks later (sweeping), so the services
 *     form one chain, one edge each. The chain is started by a W1C from a cold
 *     PSRAM stub (64 x ADDI), so the interrupts land on its PSRAM fetches; the
 *     ISR ends the chain at its 300th service (cue 0x61 before that W1C).
 *     Every edge must be serviced: exactly 300 services within the time (0x74;
 *     a lost edge stops the chain early), the stub returns 64 (0x71: an
 *     instruction lost or run twice across a trap on a fetch), then IN_IP = 0
 *     and no PLIC pending (0x78).
 *     The interrupted code is NOT promised progress while the chain runs: with
 *     the cache on, the ISR's flash lines evict the interrupted line, and the
 *     refetch can outlast the W1C-to-next-edge time for every offset (WO-75).
 *   4 watchdog interrupt mode, the first expiry forced from PSRAM code (three
 *     mtime[14] toggles) followed by cold PSRAM code: exactly one claim of id 9,
 *     no reboot, WDT_STAT 0 after EOI (0x79).
 *   5 MTIP and MEIP both pending with MIE = 0, then MIE = 1: MEI first, then
 *     MTI (cause log 0xB7; 0x75).
 * Spurious claims (id 0) are counted and reported in the signature.
 */
#include "adv.h"

#ifndef RXDIV
#define RXDIV 34
#endif
#define WCODE  0x80040000
#define WSUM   32896
#define VCODE  0x80050000
#define NRX    64
#define CLAIM  (PLIC + PL_CTX + 4)
#define G_IE   0x18
#define G_IP   0x1C

/* a0 = 0; call the 1 KB routine (cold: FENCE.I first); check 32896 */
.macro RUNW
    fence.i
    li   a0, 0
    li   t0, WCODE
    jalr ra, 0(t0)
    li   t0, WSUM
    mv   a7, a0
    li   a6, 0x71
    bne  a0, t0, test_fail
.endm
/* a4 = mtime now */
.macro TSTART
    li   t0, MTIME
    lw   a4, 0(t0)
.endm
/* fail with code if more than n clocks since TSTART */
.macro TCHECK n, code
    li   t0, MTIME
    lw   t1, 0(t0)
    sub  t1, t1, a4
    li   t0, \n
    mv   a7, s1
    li   a6, \code
    bgeu t1, t0, test_fail
.endm

    .section .text.init
    .globl _start
_start:
    ADV_ENTRY trap
    li   s0, 0
    li   s1, 0
    li   s2, 3
    li   s3, 0
    li   s5, 0
    li   s6, 0
    li   s7, 0
    /* the 1 KB routine: ADDI a0,a0,k for k = 1..256, jr ra */
    li   a0, WCODE
    li   t1, 1
1:  slli t2, t1, 20
    li   t3, 0x00050513
    or   t2, t2, t3
    sw   t2, 0(a0)
    addi a0, a0, 4
    addi t1, t1, 1
    li   t3, 257
    blt  t1, t3, 1b
    li   t2, INSN_JR_RA
    sw   t2, 0(a0)
    /* UART: divisor RXDIV (the bench follows), FIFO on, trigger 7, ERBFI */
    li   a1, UART
    li   t1, 0x80
    sb   t1, LCR(a1)
    li   t1, RXDIV
    sb   t1, DLL(a1)
    sb   zero, DLM(a1)
    li   t1, 3
    sb   t1, LCR(a1)
    li   t1, RXDIV
    sw   t1, MB_VALUE(s11)
    EVENT 0x34
    li   t1, 0xC1
    sb   t1, FCR(a1)
    li   t1, 1
    sb   t1, IER(a1)
    /* PLIC: sources 1, 4, 9 priority 1, enabled, threshold 0 */
    li   a2, PLIC
    li   t1, 1
    sw   t1, PL_PRIO * SRC_UART(a2)
    sw   t1, PL_PRIO * SRC_GPIO(a2)
    sw   t1, PL_PRIO * SRC_WDT(a2)
    li   t1, (1 << SRC_UART) | (1 << SRC_GPIO) | (1 << SRC_WDT)
    li   t2, PLIC + PL_EN
    sw   t1, 0(t2)
    li   t2, PLIC + PL_CTX
    sw   zero, 0(t2)
    li   t1, 0x800                /* MEIE */
    csrw mie, t1
    csrsi mstatus, 8

/* ── Phase 1 ── */
    li   s2, 3
    li   t1, NRX
    sw   t1, MB_VALUE(s11)
    EVENT 0x51
    TSTART
2:  RUNW
    li   t1, NRX
    bge  s1, t1, 3f
    TCHECK (NRX + 8) * 160 * RXDIV + 400000, 0x72
    j    2b
3:  lbu  t1, LSR(a1)
    andi t1, t1, LSR_OE
    beqz t1, 4f
    li   t2, 0x0E000000
    or   t2, t2, s1
    sw   t2, MB_SPARE(s11)
#if RXDIV >= 34
    mv   a7, t1
    li   a6, 0x73
    j    test_fail
#endif
4:  mv   a7, s0
    li   a6, 0x70
    bnez s0, test_fail
    SIGF s1

/* ── Phase 2: WFI at offset 0xC; the next line cold ── */
    /* VCODE: nop, nop, nop, wfi | addi a0,a0,1, jr ra */
    li   a0, VCODE
    li   t1, INSN_NOP
    sw   t1, 0(a0)
    sw   t1, 4(a0)
    sw   t1, 8(a0)
    li   t1, 0x10500073           /* wfi */
    sw   t1, 12(a0)
    li   t1, ADDI_A0(1)
    sw   t1, 16(a0)
    li   t1, INSN_JR_RA
    sw   t1, 20(a0)
    /* 2a: MIE = 0 */
    csrci mstatus, 8
    li   s1, 0
    li   s2, 3
    fence.i
    li   t1, 1
    sw   t1, MB_VALUE(s11)
    EVENT 0x51
    li   a0, 0
    li   t0, VCODE
    jalr ra, 0(t0)
    mv   a7, a0
    li   a6, 0x76
    li   t1, 1
    bne  a0, t1, test_fail
    li   t0, CLAIM
    lw   t1, 0(t0)
    mv   a7, t1
    li   t2, SRC_UART
    bne  t1, t2, test_fail
    lbu  t2, RBR(a1)
    sw   t1, 0(t0)                /* complete */
    /* 2b: MIE = 1 */
    li   s1, 0
    li   s2, 3
    csrw mscratch, zero
    fence.i
    li   t1, 1
    sw   t1, MB_VALUE(s11)
    EVENT 0x51
    csrsi mstatus, 8
    li   a0, 0
    li   t0, VCODE
    jalr ra, 0(t0)
    mv   a7, a0
    li   a6, 0x77
    li   t1, 1
    bne  a0, t1, test_fail
    mv   a7, s1
    bne  s1, t1, test_fail
    li   t1, VCODE + 16
    mv   a7, s8                   /* s8 = the last MEI's mepc (handler) */
    bne  s8, t1, test_fail

/* ── Phase 3: claim/complete against new GPIO edges ── */
    /* VCODE+0x100: sw t1, 0x1C(t0) (the W1C that starts the chain), 64 x ADDI a0,a0,1, jr ra */
    li   a0, VCODE + 0x100
    li   t1, 0x0062AE23           /* sw t1, 0x1C(t0) */
    sw   t1, 0(a0)
    li   t1, ADDI_A0(1)
    li   t2, 64
12: sw   t1, 4(a0)
    addi a0, a0, 4
    addi t2, t2, -1
    bnez t2, 12b
    li   t1, INSN_JR_RA
    sw   t1, 4(a0)
    li   s9, 300                  /* the ISR ends the chain at this service */
    li   t0, GPIO
    li   t1, 0x80
    sw   t1, G_IE(t0)
    li   t1, 0xFF
    sw   t1, G_IP(t0)             /* clear (before the cue: no toggle) */
    EVENT 0x60
    fence.i
    li   a0, 0
    li   t2, VCODE + 0x100
    jalr ra, 0(t2)                /* t0 = GPIO, t1 = 0xFF: the stub's W1C is the first toggle */
    mv   a7, a0
    li   a6, 0x71
    li   t1, 64
    bne  a0, t1, test_fail
    TSTART
5:  RUNW
    li   t1, 300
    bge  s5, t1, 6f
    mv   s1, s5
    TCHECK 3000000, 0x74
    j    5b
6:  EVENT 0x61
    mv   a7, s5
    li   a6, 0x74
    li   t1, 300
    bne  s5, t1, test_fail        /* one service per edge, no more */
    DELAY 2000
    li   t0, GPIO
    lw   t1, G_IP(t0)
    mv   a7, t1
    li   a6, 0x78
    bnez t1, test_fail
    li   t0, PLIC + PL_PEND
    lw   t1, 0(t0)
    mv   a7, t1
    bnez t1, test_fail
    li   t0, GPIO
    sw   zero, G_IE(t0)

/* ── Phase 4: watchdog interrupt mode, expiry during PSRAM fills ── */
    /* VCODE+0x40: sw zero/t1 alternating x6 to 0(t0), 40 x ADDI a0,a0,1, jr ra */
    li   a0, VCODE + 0x40
    li   t1, 0
7:  andi t2, t1, 1
    li   t3, 0x0002A023           /* sw zero, 0(t0) */
    beqz t2, 8f
    li   t3, 0x0062A023           /* sw t1, 0(t0) */
8:  sw   t3, 0(a0)
    addi a0, a0, 4
    addi t1, t1, 1
    li   t2, 6
    blt  t1, t2, 7b
    li   t1, 0
    li   t3, ADDI_A0(1)
9:  sw   t3, 0(a0)
    addi a0, a0, 4
    addi t1, t1, 1
    li   t2, 40
    blt  t1, t2, 9b
    li   t3, INSN_JR_RA
    sw   t3, 0(a0)
    sw   zero, WDT_TORR(s11)      /* TOP 0, kick */
    li   t1, 3
    sw   t1, WDT_CR(s11)          /* EN, interrupt mode */
    fence.i
    li   a0, 0
    li   t0, MTIME
    li   t1, 0x4000
    li   t2, VCODE + 0x40
    jalr ra, 0(t2)
    mv   a7, a0
    li   a6, 0x79
    li   t1, 40
    bne  a0, t1, test_fail
    DELAY 3000
    mv   a7, s6
    li   t1, 1
    bne  s6, t1, test_fail
    lw   a7, WDT_STAT(s11)
    bnez a7, test_fail
    lbu  a7, RST_CAUSE(s11)
    andi a7, a7, 4
    bnez a7, test_fail

/* ── Phase 5: MTIP + MEIP pending together ── */
    csrci mstatus, 8
    li   s3, 0
    li   s1, 0
    li   s2, 3
    li   t0, MTIMECMP
    sw   zero, 4(t0)
    sw   zero, 0(t0)              /* mtimecmp = 0: MTIP */
    li   t1, 0x880                /* MEIE | MTIE */
    csrw mie, t1
    li   t1, 8
    sw   t1, MB_VALUE(s11)
    EVENT 0x51
    TSTART
10: li   t0, PLIC + PL_PEND
    lw   t1, 0(t0)
    andi t1, t1, (1 << SRC_UART)
    bnez t1, 11f
    TCHECK 400000, 0x7A
    j    10b
11: csrr t1, mip
    li   t2, 0x880
    and  t1, t1, t2
    mv   a7, t1
    li   a6, 0x7B
    bne  t1, t2, test_fail
    csrsi mstatus, 8
    nop
    nop
    nop
    nop
    csrci mstatus, 8
    mv   a7, s3
    li   a6, 0x75
    li   t1, 0xB7
    bne  s3, t1, test_fail
    SIGF s3
    SIGF s7
    ADV_PASS

/* ── Trap handler: tp, gp, s0-s3, s5-s8 are its own, s9 it reads; t0 via mscratch ── */
    .balign 4                    /* mtvec BASE is 4-byte aligned: the low bits are its MODE field (WARL) */
trap:
    csrrw t0, mscratch, t0
    csrr tp, mcause
    bgez tp, bad_trap
    andi tp, tp, 0x1F
    slli s3, s3, 4
    or   s3, s3, tp
    li   gp, 7
    beq  tp, gp, mti
    li   gp, 11
    bne  tp, gp, bad_trap
    csrr s8, mepc
    li   gp, CLAIM
    lw   tp, 0(gp)
    beqz tp, spur
    li   gp, SRC_UART
    beq  tp, gp, uart_isr
    li   gp, SRC_GPIO
    beq  tp, gp, gpio_isr
    li   gp, SRC_WDT
    beq  tp, gp, wdt_isr
    j    bad_trap
uart_isr:
    li   gp, UART
1:  lbu  t0, LSR(gp)
    andi t0, t0, LSR_DR
    beqz t0, 2f
    lbu  t0, RBR(gp)
    addi t0, t0, -32
    beq  t0, s2, 3f
    addi s0, s0, 1                /* wrong byte or order */
3:  addi s2, s2, 7
    li   t0, 95
    blt  s2, t0, 4f
    addi s2, s2, -95
4:  addi s1, s1, 1
    j    1b
2:  j    complete
gpio_isr:
    li   gp, GPIO
    lw   t0, G_IP(gp)
    addi s5, s5, 1
    bne  s5, s9, 1f
    li   gp, 0x61                 /* the last service: stop the bench's race BEFORE this W1C, */
    sw   gp, MB_EVENT(s11)        /* so it makes no toggle and the chain ends */
    li   gp, GPIO
1:  sw   t0, G_IP(gp)             /* W1C what was seen (the bench's toggle follows) */
    j    complete
wdt_isr:
    lw   t0, WDT_EOI(s11)
    li   t0, 15
    sw   t0, WDT_TORR(s11)        /* long timeout, kick: no second expiry */
    addi s6, s6, 1
complete:
    li   gp, CLAIM
    sw   tp, 0(gp)
    csrrw t0, mscratch, t0
    mret
spur:
    addi s7, s7, 1
    csrrw t0, mscratch, t0
    mret
mti:
    li   gp, 0x80
    csrc mie, gp
    csrrw t0, mscratch, t0
    mret
bad_trap:
    csrr a7, mcause
    csrr t0, mepc
    sw   t0, MB_VALUE(s11)
    li   a6, 0x7E
    j    test_fail

    ADV_FAIL_BODY
