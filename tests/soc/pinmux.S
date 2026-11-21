# Pinmux feature selection (0x1002_0020): codes 0 DEFAULT, 1 GPIO OUT[i], 2 RTS#, 3 AUDIO, 4-7 PWM0-3.
#   1  read-back: every code 0..7 on every pin (word code * 0x11111111) reads back as written
#      (bit 4i+3 reads 0); reset value 0.
#   2  RTS# on uo_out[5] (code 2, giving up the SD CS#), the RP2350 model's flow control on (the bench
#      does this for pinmux, CTS = uo_out[5]), interrupts off: cue 1 = the bench pastes 64 characters
#      (pattern 0x20 + (7n + 3) mod 95). First the program reads nothing for 24 character times: the
#      8-deep FIFO fills, RTS# goes high at 7 entries and the model holds the rest (cue 8: the bench
#      checks pin 5 high and 7..10 characters sent). Then the program drains, slowly (3 character times between
#      pops): the model resumes, 64 in order, none lost, OE 0, no character sent against CTS.
#   3  back to the default: pin 5 = GPIO OUT bit 5 (SD CS#) again; cue 2 with OUT bit 5 low then high.
#   4  GPIO on pin 4 (UART TX gives way: OUT bit 4 drives the pin, reset high) and pin 7 (OUT bit 7, reset 1):
#      cue 3 with both low, cue 4 both high, cue 5 pinmux back to 0.
#   5  PWM0 on pin 7 (code 4, cfg = enalways, cmp0 0xBFFF), cue 6 for the bench to see the 25 % duty, cue 7
#      after the pinmux is 0 again (pin 7 = AUDIO, EN off: low).
#include "periph4.h"
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s1, PINMUX
    li   s0, UART
    lw   t0, 0(s1)
    CHECK t0, 0, 0x01
    li   t2, 0
    li   t3, 8
1:  li   t1, 0x11111111
    mul  t1, t1, t2
    sw   t1, 0(s1)
    lw   t0, 0(s1)
    CHECKR t0, t1, 0x02
    addi t2, t2, 1
    bne  t2, t3, 1b
    sw   zero, 0(s1)

    # RTS# on pin 5, the paste with flow control
    li   t0, 0x00200000
    sw   t0, 0(s1)
    lw   t1, 0(s1)
    CHECK t1, 0x00200000, 0x03
    li   t0, 0x01
    sb   t0, FCR(s0)              # FIFO on (RTS# asserts while two or more entries are free)
    li   s3, 0                    # received
    li   s4, 0                    # mismatches
    EVENT_P 1
    DELAY (24 * CHAR_CLKS)        # read nothing: RTS# must stop the paste
    EVENT_P 8
    li   s5, 4000
2:  lbu  t1, LSR(s0)
    andi t2, t1, 2
    CHECK t2, 0, 0x04             # no overrun
    andi t2, t1, 1
    bnez t2, 3f
    addi s5, s5, -1
    bnez s5, 2b
    j    4f                       # nothing more is coming
3:  lbu  t1, RBR(s0)
    li   t2, 7
    mul  t2, s3, t2
    addi t2, t2, 3
    li   t3, 95
    remu t2, t2, t3
    addi t2, t2, 0x20
    beq  t2, t1, 5f
    addi s4, s4, 1
5:  addi s3, s3, 1
    li   t2, 64
    beq  s3, t2, 4f
    li   s5, 4000
    DELAY (3 * CHAR_CLKS)
    j    2b
4:  CHECK s3, 64, 0x05
    CHECK s4, 0, 0x06
    # default map again: pin 5 = OUT bit 5
    sw   zero, 0(s1)
    li   s2, GPIO
    lw   t0, G_OUT(s2)
    andi t0, t0, 0x20
    CHECK t0, 0x20, 0x07          # reset 0xB9: bit 5 high
    lw   t0, G_OUT(s2)
    andi t0, t0, 0xDF
    sw   t0, G_OUT(s2)
    CUE 2, 400                    # bench: uo[5] low
    lw   t0, G_OUT(s2)
    ori  t0, t0, 0x20
    sw   t0, G_OUT(s2)
    DELAY 400
    # GPIO on pins 4 and 7
    li   t0, (1 << 16) | (1 << 28)
    sw   t0, 0(s1)
    lw   t0, G_OUT(s2)
    CHECK t0, 0xB9, 0x08
    li   t0, 0x29                 # bits 4 and 7 low
    sw   t0, G_OUT(s2)
    CUE 3, 400
    li   t0, 0xB9
    sw   t0, G_OUT(s2)
    CUE 4, 400
    sw   zero, 0(s1)
    CUE 5, 400                    # TX idle high again, pin 7 audio low
    # PWM0 on pin 7
    li   s6, PWM
    li   t0, 0xBFFF
    sw   t0, PWM_CMP0(s6)
    li   t0, 4 << 28
    sw   t0, 0(s1)
    li   t0, 0x1000
    sw   t0, PWM_CFG(s6)
    CUE 6, 3 << 16
    sw   zero, PWM_CFG(s6)
    sw   zero, 0(s1)
    CUE 7, 400
    j    test_pass
    EPILOGUE
