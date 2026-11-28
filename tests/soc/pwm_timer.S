# PWM slim-down negative check (the sticky, one-shot and interrupt features are removed; the name stays for
# scripts/gl/build_isa.sh). PLIC sources 5-8 are enabled (priority 1, enable word 0x1E0, threshold 0) and
# must never pend, whatever the PWM does; MEIP is polled.
#   1  cfg bits 8 (sticky) and 13 (oneshot) read 0 and ignore writes: cfg = 0x2300 reads back 0x0200 (zerocmp
#      only), and with enalways off the scaled count holds at 0 (a oneshot write did not start it).
#   2  no sticky: with enalways, cmp0 = 100, ip[0] (cfg bit 28) is set once the count passes 100; cmp0 raised to
#      0xFFFF clears it again at once (a sticky ip would stay set).
#   3  zerocmp periodic, scale 0, cmp0 = 1000: ip[0] toggles in the loop for 8 periods (high for one clock per
#      period, so the program only counts the periods through PWM_S wrapping to 0), while the PLIC pending word
#      stays 0 in bits 5-8 and MEIP stays clear: sources 5-8 never fire.
#   4  comparator 1 and the unbuilt 2/3 (cmp2/cmp3 = 0 with the counter running): pending stays 0, MEIP clear.
#include "periph4.h"
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, PWM
    PLIC_SETUP 0x1E0
    # 1: bits 8 and 13 ignored, the counter does not start
    li   t0, 0x2300
    sw   t0, PWM_CFG(s0)
    lw   t1, PWM_CFG(s0)
    li   t3, 0x3F0F
    and  t1, t1, t3
    CHECK t1, 0x0200, 0x01
    DELAY 500
    lw   t1, PWM_S(s0)
    CHECK t1, 0, 0x02
    sw   zero, PWM_CFG(s0)
    sw   zero, PWM_COUNT(s0)
    # 2: no sticky
    li   t0, 100
    sw   t0, PWM_CMP0(s0)
    li   t0, 0x1000
    sw   t0, PWM_CFG(s0)
    DELAY 600
    lw   t1, PWM_CFG(s0)
    srli t1, t1, 28
    andi t1, t1, 1
    CHECK t1, 1, 0x03             # ip[0] set: s >= cmp0
    li   t0, 0xFFFF
    sw   t0, PWM_CMP0(s0)
    DELAY 20
    lw   t1, PWM_CFG(s0)
    srli t1, t1, 28
    andi t1, t1, 1
    CHECK t1, 0, 0x04             # no sticky: ip[0] follows the comparator down
    sw   zero, PWM_CFG(s0)
    sw   zero, PWM_COUNT(s0)
    # 3: zerocmp periodic, no interrupt on the PLIC
    li   t0, 1000
    sw   t0, PWM_CMP0(s0)
    li   t0, 0x1200
    sw   t0, PWM_CFG(s0)
    li   s3, 0                    # periods seen (PWM_S falling)
    li   s4, 0                    # previous PWM_S
    li   s5, 0                    # polls
    li   s6, PLIC + PL_PEND
1:  lw   t1, PWM_S(s0)
    bge  t1, s4, 2f
    addi s3, s3, 1                # s fell: a zerocmp restart
2:  mv   s4, t1
    lw   t0, 0(s6)
    andi t0, t0, 0x1E0
    CHECK t0, 0, 0x05             # sources 5-8 never pend
    NO_MEIP 0x06
    addi s5, s5, 1
    li   t2, 4000
    blt  s5, t2, 1b
    li   t2, 3
    bgeu s3, t2, 3f
    li   a7, 0
    li   a6, 0x07                 # the PWM never restarted: the timer did not run
    j    test_fail
3:  sw   zero, PWM_CFG(s0)
    sw   zero, PWM_COUNT(s0)
    # 4: comparator 1, and cmp2 = cmp3 = 0 (not built), counter running
    sw   zero, PWM_CMP0+4(s0)
    sw   zero, PWM_CMP0+8(s0)
    sw   zero, PWM_CMP0+12(s0)
    li   t0, 0x1000
    sw   t0, PWM_CFG(s0)
    DELAY 400
    lw   t0, 0(s6)
    andi t0, t0, 0x1E0
    CHECK t0, 0, 0x08
    NO_MEIP 0x09
    lw   t0, 4(a4)
    CHECK t0, 0, 0x0A             # claim 0: nothing pending
    sw   zero, PWM_CFG(s0)
    j    test_pass
    EPILOGUE
