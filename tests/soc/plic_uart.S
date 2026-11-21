# The Linux interrupt sequences end to end: PLIC (0x0C00_0000) + 16550 on source 1, in the order the
# kernel does them (irq-sifive-plic.c, 8250 driver): mtvec; probe the PLIC (priorities, enables
# cleared, threshold 0); enable source 1; mie.MEIE; mstatus.MIE; UART FCR 0x81 (trigger 4),
# IER = ERBFI | ELSI.
#
# The testbench's RP2350 model sends, with flow control off and at full rate, a pattern whose byte n
# is 0x20 + (7n + 3) mod 95: bursts of 5, 16 and 40 characters (cues 1-3). The handler claims,
# drains while IIR != 1 (LSR, then RBR while DR), completes. Then:
#   cue 4  8 characters, echoed through a THRE interrupt (ETBEI set by the handler, cleared when the
#          echo buffer is empty)
#   cue 5  a break: BI entry + RLS
#   cue 6  a character with source 1 at priority 0 (masked): no interrupt, claim reads 0; priority
#          back to 1: the interrupt arrives
#   cue 7  a character with the source disabled in the enable word: the same
#   cue 8  the Linux EOI path (irq-sifive-plic.c), interrupts off, mip polled: one character below the
#          trigger, so the CTI interrupt stays asserted until RBR is read. Claim 1; disable the source
#          and complete: a completion of a disabled source is ignored, so the gateway stays closed and,
#          although the UART still asserts, re-enabling raises no new interrupt (claim 0, MEIP clear);
#          complete with the source enabled: the gateway reopens and the asserting UART is pending
#          again (claim 1); drain it; then the driver's own EOI (enable, complete, disable) and
#          re-enable: nothing pending
# Every received byte is checked against the pattern in order, so a byte popped twice (a select held
# in the bus's second phase) or lost shows as a mismatch. Final checks: 72 characters received, OE 0,
# 0 mismatches, 1 break, 0 spurious claims, 0 claims of a source other than 1 (the SPI is source 2, the
# gamepad 3, the PWM comparators 5-8: none is enabled here), the masked / disabled phases took no
# interrupt.
# Handler: t0-t4, s-registers 1, 3-7, 10, a1-a3; main code keeps off them while interrupts are on.
#include "periph4.h"
#define PL_PRIO   0x04
#define ECHO_BUF  0x80000100

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, UART
    li   s2, PLIC
    li   a4, PLIC + PL_CTX
    li   s1, 0                   # characters received
    li   a1, 0                   # claims of a source other than 1
    li   s3, 0                   # interrupts taken
    li   s4, 0                   # OE seen
    li   s5, 0                   # claims that returned 0
    li   s6, 0                   # pattern mismatches
    li   s7, 0                   # breaks
    li   s8, 0                   # echo on
    li   s10, 0                  # THRE interrupts
    li   a2, ECHO_BUF            # echo buffer: write, read pointers
    li   a3, ECHO_BUF
    la   t0, handler
    csrw mtvec, t0
    # PLIC probe: priority 1 for sources 1..9, enables cleared, threshold 0
    li   t0, 1
    li   t1, 9
    addi t2, s2, PL_PRIO
1:  sw   t0, 0(t2)
    addi t2, t2, 4
    addi t1, t1, -1
    bnez t1, 1b
    li   t2, 0x2000
    add  t2, t2, s2
    sw   zero, 0(t2)             # enables cleared
    lw   t0, 0(t2)
    CHECK t0, 0, 0x01
    sw   zero, 0(a4)             # threshold 0
    li   t0, 2
    sw   t0, 0(t2)               # enable source 1
    lw   t0, 0(t2)
    CHECK t0, 2, 0x02
    lw   t0, 4(a4)               # nothing pending: claim 0
    CHECK t0, 0, 0x03
    # UART: FIFOs on, trigger 8; interrupts on
    li   t0, 0x81
    sb   t0, FCR(s0)
    li   t0, 0x05
    sb   t0, IER(s0)
    li   t0, 0x800
    csrw mie, t0                 # MEIE
    csrsi mstatus, 8             # MIE

    # ---- three bursts, flow control off ----
    EVENT 1
    li   a5, 5
    jal  ra, wait_rx
    EVENT 2
    li   a5, 21
    jal  ra, wait_rx
    EVENT 3
    li   a5, 61
    jal  ra, wait_rx

    # ---- echo through the THRE interrupt ----
    li   s8, 1
    EVENT 4
    li   a5, 69
    jal  ra, wait_rx
    li   a6, 20000               # the echo drains: buffer empty and the shifter idle
2:  bne  a2, a3, 3f
    lbu  t5, LSR(s0)
    andi t5, t5, LSR_TEMT
    bnez t5, 4f
3:  addi a6, a6, -1
    bnez a6, 2b
    li   a7, 0
    li   a6, 0x10
    j    test_fail
4:  li   s8, 0

    # ---- a break ----
    EVENT 5
    li   a6, 20000
5:  bnez s7, 6f
    addi a6, a6, -1
    bnez a6, 5b
    li   a7, 0
    li   a6, 0x11
    j    test_fail
6:
    # ---- masked: priority 0 ----
    sw   zero, PL_PRIO(s2)
    mv   s9, s3
    EVENT 6
    DELAY 3000
    CHECKR s3, s9, 0x20          # no interrupt
    lw   t0, 4(a4)               # nothing pending
    CHECK t0, 0, 0x21
    li   t0, 1
    sw   t0, PL_PRIO(s2)         # unmasked: the character interrupts
    li   a5, 70
    jal  ra, wait_rx

    # ---- disabled in the enable word ----
    li   t2, 0x2000
    add  t2, t2, s2
    sw   zero, 0(t2)
    mv   s9, s3
    EVENT 7
    DELAY 3000
    CHECKR s3, s9, 0x30
    lw   t0, 4(a4)
    CHECK t0, 0, 0x31
    li   t0, 2
    sw   t0, 0(t2)
    li   a5, 71
    jal  ra, wait_rx

    # ---- the Linux EOI path, polled (interrupts off) ----
    csrci mstatus, 8
    EVENT 8
    li   a6, 400000
17: csrr t5, mip
    srli t5, t5, 11
    andi t5, t5, 1
    bnez t5, 18f
    addi a6, a6, -1
    bnez a6, 17b
    li   a7, 0
    li   a6, 0x60
    j    test_fail
18: lw   t0, 4(a4)
    CHECK t0, 1, 0x61            # claim: the UART
    li   t2, PLIC + PL_EN
    sw   zero, 0(t2)             # the source disabled
    sw   t0, 4(a4)               # completed while disabled: ignored, the gateway stays closed
    li   t0, 2
    sw   t0, 0(t2)               # enabled again, the UART still asserts
    DELAY 20
    lw   t0, 4(a4)
    CHECK t0, 0, 0x62            # nothing pending
    NO_MEIP 0x63
    li   t0, 1
    sw   t0, 4(a4)               # completed with the source enabled: the gateway reopens
    DELAY 20
    lw   t0, 4(a4)
    CHECK t0, 1, 0x64            # the asserting UART is pending again
    lbu  t1, RBR(s0)             # the character (pattern byte 71 = 0x20 + 25), the interrupt drops
    CHECK t1, 0x39, 0x65
    addi s1, s1, 1
    li   t0, 2
    sw   t0, 0(t2)               # the driver's EOI: enable ...
    li   t0, 1
    sw   t0, 4(a4)               # ... complete ...
    sw   zero, 0(t2)             # ... disable
    li   t0, 2
    sw   t0, 0(t2)               # and back on
    DELAY 20
    lw   t0, 4(a4)
    CHECK t0, 0, 0x66
    NO_MEIP 0x67

    # ---- results ----
    CHECK s1, 72, 0x40
    CHECK s4, 0, 0x41            # no overrun
    CHECK s6, 0, 0x42            # every byte in order, none twice
    CHECK s7, 1, 0x43
    CHECK s5, 0, 0x44            # no spurious claim
    CHECK a1, 0, 0x48            # no claim of another source
    CHECK a2, ECHO_BUF + 8, 0x45
    CHECKR a3, a2, 0x46
    blt  s3, s10, 7f
    VALUE s1
    VALUE s3
    j    test_pass
7:  li   a7, 0
    li   a6, 0x47
    j    test_fail

# wait until s1 >= a5 (interrupts do the work)
wait_rx:
    li   a6, 20000
1:  bge  s1, a5, 2f
    addi a6, a6, -1
    bnez a6, 1b
    mv   a7, s1
    li   a6, 0x50
    j    test_fail
2:  ret

    .balign 4
handler:
    addi s3, s3, 1
    lw   t0, 4(a4)               # claim
    bnez t0, 1f
    addi s5, s5, 1               # spurious
    mret
1:  li   t1, 1
    bne  t0, t1, 9f              # not the UART: counted (a1), completed
10: lbu  t1, IIR(s0)
    andi t2, t1, 1
    bnez t2, 8f                  # IIR == 1: nothing left
    andi t2, t1, 0xF
    li   t3, 2
    bne  t2, t3, 11f
    # THRE: send the next echo byte, or stop
    addi s10, s10, 1
    bne  a2, a3, 12f
    li   t2, 0x05
    sb   t2, IER(s0)
    j    10b
12: lbu  t2, 0(a3)
    addi a3, a3, 1
    sb   t2, THR(s0)
    j    10b
11: # RDA, timeout or RLS: LSR, then drain
13: lbu  t2, LSR(s0)
    andi t3, t2, 2
    beqz t3, 14f
    addi s4, s4, 1               # OE
14: andi t3, t2, 1
    beqz t3, 10b
    andi t3, t2, 0x10
    beqz t3, 15f
    lbu  t1, RBR(s0)             # break entry
    addi s7, s7, 1
    j    13b
15: lbu  t1, RBR(s0)
    li   t3, 7
    mul  t3, s1, t3
    addi t3, t3, 3
    li   t4, 95
    remu t3, t3, t4
    addi t3, t3, 0x20
    beq  t3, t1, 16f
    addi s6, s6, 1
16: addi s1, s1, 1
    beqz s8, 13b
    sb   t1, 0(a2)               # echo it
    addi a2, a2, 1
    li   t2, 0x07
    sb   t2, IER(s0)             # ETBEI on
    j    13b
8:  sw   t0, 4(a4)               # complete
    mret
9:  addi a1, a1, 1
    sw   t0, 4(a4)
    mret
    EPILOGUE
