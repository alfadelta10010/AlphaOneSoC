# SD CS# on GPIO OUT bit 5 and uo_out[5] (default pinmux map): OUT resets 0xB9 (bit 5 high), a store
# that clears bit 5 drops uo_out[5] (cue 1 for the bench to sample it one clock after the store reaches
# the pin flop), setting it raises it (cue 2). The other pins do not move: bits 7, 4, 3, 0 keep their
# levels; uo_out[7] is the audio source (low, EN off), uo_out[4] the UART TX (idle high) by default, so
# OUT bits 7 and 4 are written 0 and 1 without reaching their pins. The SD card's own CS# traffic is
# in sd_init.S / sd_reboot.S.
#include "periph4.h"
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, GPIO
    lw   t0, G_OUT(s0)
    CHECK t0, 0xB9, 0x01
    li   t0, 0x99                 # bit 5 low, the rest as reset
    sw   t0, G_OUT(s0)
    lw   t1, G_OUT(s0)
    CHECK t1, 0x99, 0x02
    CUE 1, 400
    li   t0, 0xB9
    sw   t0, G_OUT(s0)
    CUE 2, 400
    # bits 7 and 4 toggled: the default map's pins 7 and 4 stay on AUDIO and UART TX
    li   t0, 0x29
    sw   t0, G_OUT(s0)
    CUE 3, 400
    li   t0, 0xB9
    sw   t0, G_OUT(s0)
    CUE 4, 400
    j    test_pass
    EPILOGUE
