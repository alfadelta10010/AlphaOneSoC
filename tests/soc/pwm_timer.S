# PWM as a timer: zerocmp + sticky periodic interrupt on PLIC source 5 (comparator 0), oneshot, software
# clear. MEIP is polled, with the PLIC claim / complete in the loop.
#   periodic scale 0, cmp0 = 4000: cfg = enalways | zerocmp | sticky. 6 interrupts, each claim = 5, ip[0]
#            (cfg bit 28) set until cleared by a byte store to cfg lane 3; the mtime distance from the
#            1st to the 6th claim is 5 x (cmp0 + 1) = 20005 clocks +-400 (the loop runs from flash, so the periods are long).
#   scale 2: cmp0 = 1000, period (1000 << 2) + 1 = 4001 clocks; 5 periods from the 1st to the 6th: 20005 +-400.
#   oneshot: cfg = oneshot | zerocmp | sticky, cmp0 = 300: one interrupt, then enoneshot (bit 13) reads 0
#            and, after the clear, no second interrupt in 3000 clocks (claim 0).
#   no sticky: ip follows the comparator (high while s >= cmp0), enalways off stops the count (PWM_S holds).
# Handler-free: the program clears ip[0] by `sb zero, 3(pwm)` and completes the claim.
#include "periph4.h"
#define TOL 400
.macro PERIOD_RUN cfg, cmp, expect, code
    li   t0, \cmp
    sw   t0, PWM_CMP0(s0)
    li   t0, \cfg
    sw   t0, PWM_CFG(s0)
    li   s3, 6
    li   s4, 0                    # mtime at the 1st claim
1:  WAIT_MEIP \code
    li   t6, MTIME
    lw   s5, 0(t6)
    CLAIM SRC_PWM0, \code + 1
    lw   t1, PWM_CFG(s0)
    srli t1, t1, 28
    andi t1, t1, 1
    CHECK t1, 1, \code + 2        # ip[0] set
    sb   zero, PWM_CFG+3(s0)      # clear ip
    COMPLETE
    li   t6, 6
    bne  s3, t6, 2f
    mv   s4, s5                   # first claim: time stamp
2:  addi s3, s3, -1
    bnez s3, 1b
    sub  t1, s5, s4
    li   t2, \expect - TOL
    li   a7, 0
    li   a6, \code + 3
    blt  t1, t2, test_fail1
    li   t2, \expect + TOL
    bgt  t1, t2, test_fail1
    sw   zero, PWM_CFG(s0)        # stop
    sb   zero, PWM_CFG+3(s0)
.endm
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, PWM
    PLIC_SETUP (1 << SRC_PWM0)
    PERIOD_RUN 0x1300, 4000, 20005, 0x10
    PERIOD_RUN 0x1302, 1000, 20005, 0x20
    sw   zero, PWM_COUNT(s0)      # restart the count
    NO_MEIP 0x30

    # one-shot
    li   t0, 300
    sw   t0, PWM_CMP0(s0)
    li   t0, 0x2300               # enoneshot | zerocmp | sticky
    sw   t0, PWM_CFG(s0)
    WAIT_MEIP 0x40
    CLAIM SRC_PWM0, 0x41
    lw   t1, PWM_CFG(s0)
    srli t2, t1, 13
    andi t2, t2, 1
    CHECK t2, 0, 0x42             # enoneshot cleared by the match
    srli t1, t1, 28
    andi t1, t1, 1
    CHECK t1, 1, 0x43
    sb   zero, PWM_CFG+3(s0)
    COMPLETE
    DELAY 3000
    NO_MEIP 0x44
    lw   t0, 4(a4)
    CHECK t0, 0, 0x45
    # enalways off: the scaled count holds
    lw   t1, PWM_S(s0)
    DELAY 500
    lw   t2, PWM_S(s0)
    CHECKR t1, t2, 0x46
    j    test_pass
test_fail1:
    mv   a7, t1
    j    test_fail
    EPILOGUE
