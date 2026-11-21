# The pwm-sifive driver's sequence on PWM0, routed to uo_out[2] through the pinmux (code 4):
# pwmcfg = EN_ALWAYS (bit 12) | scale, PWMCMP0 = 0xFFFF - frac. The bench counts the clocks pin 2 is high
# per period: 0x10000 - cmp at scale 0, scaled by 2^scale at scale 1 and 2 (period 2^(16 + scale)).
#   cue 1 scale 0, cmp0 0xBFFF    cue 2 scale 1, cmp0 0xBFFF    cue 3 scale 2, cmp0 0x7FFF
#   cue 4 (after pinmux back to 0 and PWM off): pin 2 is the OLED D/C again, GPIO OUT bit 2 = 0
# WO-63: pwmcmp2/3 are not built (read 0xFFFF = duty 0 for pwm-sifive get_state, writes ignored); ip[3:2] read 0 whatever lane 3 is written.
# Each measuring phase runs for 3 periods. Register read-backs are checked here.
#include "periph4.h"
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, PWM
    li   s1, PINMUX
    lw   t0, PWM_CFG(s0)
    li   t3, 0x100F
    and  t0, t0, t3
    CHECK t0, 0, 0x01
    lw   t0, PWM_CMP0(s0)
    CHECK t0, 0xFFFF, 0x02
    li   t0, 4 << 8               # pin 2 = PWM0
    sw   t0, 0(s1)
    lw   t1, 0(s1)
    CHECK t1, 4 << 8, 0x03

    li   t0, 0xFFFF
    sw   t0, PWM_CMP0+8(s0)
    sw   t0, PWM_CMP0+12(s0)
    lw   t1, PWM_CMP0+8(s0)
    CHECK t1, 0xFFFF, 0x09
    lw   t1, PWM_CMP0+12(s0)
    CHECK t1, 0xFFFF, 0x0A
    sw   zero, PWM_CMP0+8(s0)     # a write changes nothing: still 0xFFFF
    sw   zero, PWM_CMP0+12(s0)
    lw   t1, PWM_CMP0+8(s0)
    CHECK t1, 0xFFFF, 0x0C
    lw   t1, PWM_CMP0+12(s0)
    CHECK t1, 0xFFFF, 0x0D
    li   t0, 0xC0
    sb   t0, PWM_CFG+3(s0)        # ip[3:2] = 3 is ignored
    lw   t1, PWM_CFG(s0)
    srli t1, t1, 28
    CHECK t1, 0, 0x0B
    li   t0, 0xBFFF
    sw   t0, PWM_CMP0(s0)
    li   t0, 0x1000
    sw   t0, PWM_CFG(s0)
    lw   t1, PWM_CMP0(s0)
    CHECK t1, 0xBFFF, 0x04
    lw   t1, PWM_CFG(s0)
    li   t3, 0x100F
    and  t1, t1, t3
    CHECK t1, 0x1000, 0x05
    EVENT_P 1
    DELAY (3 << 16)
    li   t0, 0x1001
    sw   t0, PWM_CFG(s0)
    lw   t1, PWM_CFG(s0)
    li   t3, 0x100F
    and  t1, t1, t3
    CHECK t1, 0x1001, 0x06
    EVENT_P 2
    DELAY (3 << 17)
    li   t0, 0x7FFF
    sw   t0, PWM_CMP0(s0)
    li   t0, 0x1002
    sw   t0, PWM_CFG(s0)
    EVENT_P 3
    DELAY (3 << 18)
    sw   zero, PWM_CFG(s0)        # PWM stopped, pinmux back to the default
    sw   zero, 0(s1)
    lw   t1, 0(s1)
    CHECK t1, 0, 0x07
    li   s2, GPIO
    lw   t1, G_OUT(s2)
    andi t1, t1, 4
    CHECK t1, 0, 0x08             # OUT bit 2 resets 0: pin 2 low again
    CUE 4, 2000
    j    test_pass
    EPILOGUE
