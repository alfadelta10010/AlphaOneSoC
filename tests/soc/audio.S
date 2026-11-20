# Audio block (0x1003_0100) on uo_out[7] (the default pinmux map). Every phase is a cue, then a long
# delay while the bench's monitor measures pin 7 (high clocks per 256-clock PWM frame, tone period).
#   cue 1  voice 0 alone: V 15, O 1, P 15       tone period 16 * 2^1 * 2 * (15 + 1) = 1024 clocks
#   cue 2  voice 1 alone: V 15, O 2, P 9        16 * 4 * 2 * 10 = 1280
#   cue 3  voice 2 alone: V 15, O 0, P 40       16 * 1 * 2 * 41 = 1312
#   cue 4  noise alone: V 15, R 2 (activity on the pin, no fixed period)
#   cue 5  PCM mode (CTRL = 3), sample 0x80: 128 high clocks per frame
#   cue 6  PCM sample 0x00: pin low; cue 7  sample 0xFF: 255 high clocks per frame (or per the RTL's rule)
#   cue 8  EN = 0 again: pin 0
# Register read-backs: CTRL bits 1:0 and the PCM sample.
#include "periph4.h"
#define PH 60000
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, AUDIO
    lw   t0, AU_CTRL(s0)
    andi t0, t0, 3
    CHECK t0, 0, 0x01
    li   t0, 1
    sw   t0, AU_CTRL(s0)
    lw   t1, AU_CTRL(s0)
    andi t1, t1, 3
    CHECK t1, 1, 0x02
    li   t0, (15 << 16) | (1 << 12) | 15
    sw   t0, AU_TONE0(s0)
    CUE 1, PH
    sw   zero, AU_TONE0(s0)
    li   t0, (15 << 16) | (2 << 12) | 9
    sw   t0, AU_TONE1(s0)
    CUE 2, PH
    sw   zero, AU_TONE1(s0)
    li   t0, (15 << 16) | 40
    sw   t0, AU_TONE2(s0)
    CUE 3, PH
    sw   zero, AU_TONE2(s0)
    li   t0, (15 << 16) | 2
    sw   t0, AU_NOISE(s0)
    CUE 4, PH
    sw   zero, AU_NOISE(s0)
    li   t0, 3
    sw   t0, AU_CTRL(s0)          # PCM mode
    lw   t1, AU_CTRL(s0)
    andi t1, t1, 3
    CHECK t1, 3, 0x03
    li   t0, 0x80
    sw   t0, AU_PCM(s0)
    lw   t1, AU_PCM(s0)
    andi t1, t1, 0xFF
    CHECK t1, 0x80, 0x04
    CUE 5, 20000
    sw   zero, AU_PCM(s0)
    CUE 6, 20000
    li   t0, 0xFF
    sw   t0, AU_PCM(s0)
    CUE 7, 20000
    sw   zero, AU_CTRL(s0)        # EN off
    li   t0, 0x80
    sw   t0, AU_PCM(s0)
    CUE 8, 20000
    j    test_pass
    EPILOGUE
