# Audio block (0x1003_0100), one square voice, on uo_out[7] (the default pinmux map). Each phase turns EN off,
# programs the tone, sends the cue, then turns EN on (the counters restart, so every rising-edge distance on
# the pin is exact from the first edge); the bench measures the distances on pin 7 until the next cue.
#   cue 1  O 1, P 15       tone period 16 * 2^1 * 2 * (15 + 1) = 1024 clocks
#   cue 2  O 2, P 9        16 * 4 * 2 * 10 = 1280
#   cue 3  O 0, P 40       16 * 1 * 2 * 41 = 1312
#   cue 4  EN = 0 again: pin low
# Register read-backs: CTRL is EN only (bit 1, the old PCM bit, reads 0); TONE0 = {O, P} with no volume bits;
# every other offset reads 0 and ignores writes.
#include "periph4.h"
#define PH 60000
.macro TONE_PHASE n, o, p
    sw   zero, AU_CTRL(s0)
    li   t0, ((\o) << 12) | (\p)
    sw   t0, AU_TONE0(s0)
    EVENT_P \n
    li   t0, 1
    sw   t0, AU_CTRL(s0)
    DELAY PH
.endm
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, AUDIO
    lw   t0, AU_CTRL(s0)
    CHECK t0, 0, 0x01
    li   t0, 3
    sw   t0, AU_CTRL(s0)          # bit 1 is not built
    lw   t1, AU_CTRL(s0)
    CHECK t1, 1, 0x02
    sw   zero, AU_CTRL(s0)
    li   t0, 0x000FFFFF           # volume bits (19:16) and the bit above P/O are not built
    sw   t0, AU_TONE0(s0)
    lw   t1, AU_TONE0(s0)
    li   t2, 0x7FFF
    CHECKR t1, t2, 0x03
    li   t0, -1
    sw   t0, AU_TONE1(s0)
    sw   t0, AU_TONE2(s0)
    sw   t0, AU_NOISE(s0)
    sw   t0, AU_PCM(s0)
    lw   t1, AU_TONE1(s0)
    CHECK t1, 0, 0x04
    lw   t1, AU_TONE2(s0)
    CHECK t1, 0, 0x05
    lw   t1, AU_NOISE(s0)
    CHECK t1, 0, 0x06
    lw   t1, AU_PCM(s0)
    CHECK t1, 0, 0x07
    TONE_PHASE 1, 1, 15
    TONE_PHASE 2, 2, 9
    TONE_PHASE 3, 0, 40
    sw   zero, AU_CTRL(s0)        # EN off
    EVENT_P 4
    DELAY 20000
    j    test_pass
    EPILOGUE
