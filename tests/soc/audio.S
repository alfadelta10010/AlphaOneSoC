# PWM1 tone test (the audio block is gone: PWM1 on pin 7 plays the tones), PWM shared counter: tone = scale S, zerocmp,
# cmp0 = N, cmp1 = N/2. The period is N * 2^S + 1 clocks (s counts 0..N-1 for 2^S clocks each and sits on N for one clock
# before zerocmp restarts it), the pin is ip[1] = s >= cmp1 (square, 50 %). Pin 7 is PWM1 by construction (no pinmux code);
# pin 6 is mapped to PWM0 (code 4): during a tone PWM0 shares the counter, so pin 6 pulses once per period (ip[0] = s >= cmp0,
# one clock). The Korobeiniki notes (equal tempered, A4 = 440 Hz at 62.5 MHz), the smallest S with cmp0 <= 65535:
#   note S   cmp0   cmp1   period (clocks)    note S   cmp0   cmp1   period
#   E2   4  47402  23701   758433      D5   1  53206  26603   106413
#   A2   4  35511  17755   568177      E5   1  47401  23700    94803
#   E4   2  47402  23701   189609      F5   1  44741  22370    89483
#   A4   2  35511  17755   142045      G5   1  39860  19930    79721
#   B4   1  63274  31637   126549      A5   1  35511  17755    71023
#   C5   1  59722  29861   119445
# Cue n (1-11) = note n: the program restarts the counter (PWMCOUNT write), programs cmp0/cmp1, sends the cue, then
# enables (enalways | zerocmp | S); the bench measures the rising-edge distances on pin 7 until the next cue
# (+- 1 clock of the table; each phase runs 1.6 periods, the A4 phase 2.6) and, in the A4 phase, the pulses on pin 6. Cue 12: tone off, pin 7 low.
# Window: 0x1003_0100 is the PWM again (the slot aliases it), checked here.
#include "periph4.h"
.macro TONE n, s, c0, c1, per, k
    li   t0, 0xFFFF                # quiesce first: comparators out of reach (the pin falls cleanly), then stop and
    sw   t0, PWM_CMP0+4(s0)        # restart the counter. A cfg write first would clear ip for a clock and ip would
    sw   t0, PWM_CMP0(s0)          # rise again from the old count: a spurious edge
    sw   zero, PWM_CFG(s0)
    sw   zero, PWM_COUNT(s0)
    li   t0, \c1
    sw   t0, PWM_CMP0+4(s0)
    li   t0, \c0
    sw   t0, PWM_CMP0(s0)
    EVENT_P \n
    li   t0, 0x1200 | \s
    sw   t0, PWM_CFG(s0)
    DELAY ((\per * \k) / 5 + 3000)
.endm
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, PWM
    li   s1, PINMUX
    li   t0, 4 << 24
    sw   t0, 0(s1)                 # pin 6 = PWM0 (the shared-counter check)
    li   t0, 0x1234
    sw   t0, PWM_CMP0(s0)
    li   t2, AUDIO
    lw   t1, PWM_CMP0(t2)          # the old audio window aliases the PWM (slot 3 is all PWM)
    CHECKR t1, t0, 0x01
    li   t0, 0xFFFF
    sw   t0, PWM_CMP0(s0)
    TONE 1, 4, 47402, 23701, 758433, 8      # E2
    TONE 2, 4, 35511, 17755, 568177, 8      # A2
    TONE 3, 2, 47402, 23701, 189609, 8      # E4
    TONE 4, 2, 35511, 17755, 142045, 13      # A4
    TONE 5, 1, 63274, 31637, 126549, 8      # B4
    TONE 6, 1, 59722, 29861, 119445, 8      # C5
    TONE 7, 1, 53206, 26603, 106413, 8      # D5
    TONE 8, 1, 47401, 23700, 94803, 8      # E5
    TONE 9, 1, 44741, 22370, 89483, 8      # F5
    TONE 10, 1, 39860, 19930, 79721, 8      # G5
    TONE 11, 1, 35511, 17755, 71023, 8      # A5
    li   t0, 0xFFFF                # tone off: comparators out of reach, stop, restart the counter: pin 7 low
    sw   t0, PWM_CMP0+4(s0)
    sw   t0, PWM_CMP0(s0)
    sw   zero, PWM_CFG(s0)
    sw   zero, PWM_COUNT(s0)
    EVENT_P 12
    DELAY 20000
    sw   zero, 0(s1)
    j    test_pass
    EPILOGUE
