# The first eight notes of Korobeiniki (the Tetris theme, E5 B4 C5 D5 C5 B4 A4 A4) on the one audio voice,
# uo_out[7]. One cue per note; the table is audio.v's header (equal-tempered, A4 = 440 Hz). Each note: EN off,
# tone, cue, EN on, hold for 2.3 periods; the counters restart with EN, so the bench measures exact
# rising-edge distances of 32 * 2^O * (P + 1) clocks on the pin. A real player would write the next note
# with EN left on (the new P takes effect at the next reload) and time notes from mtime.
#include "periph4.h"
.macro NOTE n, o, p
    sw   zero, AU_CTRL(s0)
    li   t0, ((\o) << 12) | (\p)
    sw   t0, AU_TONE0(s0)
    EVENT_P \n
    li   t0, 1
    sw   t0, AU_CTRL(s0)
    DELAY ((32 << (\o)) * ((\p) + 1) * 23 / 10)
.endm
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, AUDIO
    NOTE 1, 0, 2962               # E5   659.17 Hz
    NOTE 2, 0, 3954               # B4   493.84 Hz
    NOTE 3, 0, 3732               # C5   523.21 Hz
    NOTE 4, 0, 3324               # D5   587.41 Hz
    NOTE 5, 0, 3732               # C5
    NOTE 6, 0, 3954               # B4
    NOTE 7, 1, 2218               # A4   440.09 Hz
    NOTE 8, 1, 2218               # A4
    sw   zero, AU_CTRL(s0)
    EVENT_P 9
    DELAY 20000
    j    test_pass
    EPILOGUE
