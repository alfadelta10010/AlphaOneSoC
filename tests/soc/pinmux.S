# Pinmux feature selection (0x1002_0020): code 0 DEFAULT everywhere, pin 5 code 2 RTS#, pin 6 code 4 PWM0; pin 7 is PWM1 (no code).
#   1  read-back / WARL: every code 0..7 on every pin (word code * 0x11111111). Only pin 5 code 2 (RTS#) and pin 6 code 4
#      (PWM0) are legal (pin 7 is PWM1 always, no code); every other code stores 0 and reads 0. Expected read-back
#      0x00200000 for code 2, 0x04000000 for 4, 0 otherwise (bit 4i+3 reads 0); reset value 0.
#   2  RTS# on uo_out[5] (code 2, giving up the SD CS#), the RP2350 model's flow control on (the bench
#      does this for pinmux, CTS = uo_out[5]), interrupts off: cue 1 = the bench pastes 64 characters
#      (pattern 0x20 + (7n + 3) mod 95). First the program reads nothing for 24 character times: the
#      8-deep FIFO fills, RTS# goes high at 7 entries and the model holds the rest (cue 8: the bench
#      checks pin 5 high and 7..10 characters sent). Then the program drains, slowly (3 character times between
#      pops): the model resumes, 64 in order, none lost, OE 0, no character sent against CTS.
#   3  back to the default: pin 5 = GPIO OUT bit 5 (SD CS#) again; cue 2 with OUT bit 5 low then high.
#   4  illegal codes leave the pins alone: pin 4 = 2, pin 5 = 4, pin 6 = 2, pin 7 = 4 read back 0; cue 3: UART TX
#      (uo_out[4]) idle high and PWM1 (uo_out[7]) low, as in the default map; then pinmux 0 again, cue 4.
#   5  PWM1 on pin 7 (fixed, cmp1 0xBFFF, cfg = enalways), cue 6 for the bench to see the 25 % duty (cmp0 stays
#      0xFFFF: PWM0 would be silent), cue 7 after the PWM is off and cmp1 is back at 0xFFFF (pin 7 low).
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
    li   t4, 0
    li   t5, 2
    bne  t2, t5, 4f
    li   t4, 0x00200000
4:  li   t5, 4
    bne  t2, t5, 5f
    li   t4, 0x04000000
5:  CHECKR t0, t4, 0x02
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
    # illegal codes: pin 4 = 2, pin 5 = 4, pin 6 = 2, pin 7 = 4 all store 0
    li   t0, (2 << 16) | (4 << 20) | (2 << 24) | (4 << 28)
    sw   t0, 0(s1)
    lw   t0, 0(s1)
    CHECK t0, 0, 0x08
    CUE 3, 400                    # bench: uo[4] high (UART TX idle), uo[7] low (PWM1 idle)
    sw   zero, 0(s1)
    CUE 4, 400
    # PWM1 on pin 7
    li   s6, PWM
    li   t0, 0xBFFF
    sw   t0, PWM_CMP0+4(s6)
    li   t0, 0x1000
    sw   t0, PWM_CFG(s6)
    CUE 6, 3 << 16
    sw   zero, PWM_CFG(s6)
    li   t0, 0xFFFF
    sw   t0, PWM_CMP0+4(s6)
    sw   zero, PWM_COUNT(s6)
    sw   zero, 0(s1)
    CUE 7, 400
    j    test_pass
    EPILOGUE
