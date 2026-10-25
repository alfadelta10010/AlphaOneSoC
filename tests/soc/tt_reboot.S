# The TinyTapeout top level through a reboot, from the pins alone
# (tb/tb_tt_um.v, +TEST=reboot). Like tt_pins.S it reports over the UART and
# touches nothing the pins do not show, so the same run works on a netlist.
#
# Every boot sets the UART divisor to 1 first (16 clocks a bit, the rate the
# testbench's UART runs at): a reboot resets the UART, and its divisor comes
# back as the SoC's default. Each boot then sends its letter and seven bytes:
# RESET_CAUSE, BOOT_MODE, STRAPS and CHIP_ID (4 bytes, little-endian). The boot
# is told by RESET_CAUSE (SOFT, WDT) and BOOT_MODE, which a reboot keeps.
#
#   boot 1  'b'  cause 0x1, bm 0     GPIO OUT = 0xC6 (not the 0x09 the pins show
#                                    in reset), BOOT_MODE = 0x5A; cue 'r', then
#                                    FINISH = 0x7777 (reboot)
#   boot 2  'B'  cause 0x3, bm 0x5A  SPI EN set (MOSI and SCK come from the
#                                    transmitter), BOOT_MODE = 0xA5; cue 'R',
#                                    then a reboot again
#   boot 3  'C'  cause 0x3, bm 0xA5  sends 'Z' and spins
#   'Z'          GPIO IN bit 7 is the testbench's "stop" pin: after its last pin
#                reset the program sends 'Z' and spins
#
# A cue is a byte the testbench times from; the program then waits for the
# UART's last stop bit (TEMT) before it acts.
#include "periph.h"

/* Send r and wait until its stop bit has gone (clobbers t4, t5). */
.macro PUTC r
    sb   \r, THR(s0)
    WAIT_LSR s0, LSR_TEMT
.endm
/* A boot's letter, then RESET_CAUSE, BOOT_MODE, STRAPS and CHIP_ID. */
.macro HEADER letter
    li   t1, \letter
    PUTC t1
    lw   t1, 4(s11)
    PUTC t1
    lw   t1, 8(s11)
    PUTC t1
    lw   t1, 0x10(s11)
    PUTC t1
    lw   t2, 0xC(s11)
    li   t3, 4
1:  PUTC t2
    srli t2, t2, 8
    addi t3, t3, -1
    bnez t3, 1b
.endm

    .section .text.init
    .globl _start
_start:
    li   s0, UART
    li   s1, GPIO
    li   s11, SYSCON
    li   t0, 0x80
    sb   t0, LCR(s0)             # DLAB
    li   t0, 1
    sb   t0, DLL(s0)
    sb   zero, DLM(s0)
    sb   zero, LCR(s0)
    lw   t0, G_IN(s1)
    andi t0, t0, 0x80            # the testbench's stop pin
    bnez t0, stop
    lw   s2, 4(s11)              # RESET_CAUSE
    lw   s3, 8(s11)              # BOOT_MODE
    andi t0, s2, 2
    beqz t0, boot1
    li   t0, 0x5A
    beq  s3, t0, boot2
    j    boot3

boot1:
    HEADER 'b'
    li   t0, 0xC6
    sw   t0, G_OUT(s1)
    li   t0, 0x5A
    sw   t0, 8(s11)              # BOOT_MODE
    li   t1, 'r'
    PUTC t1
    li   t0, 0x7777
    sw   t0, 0(s11)              # FINISH: reboot
1:  j    1b

boot2:
    HEADER 'B'
    li   t0, 1
    sw   t0, G_CTRL(s1)          # SPI EN
    li   t0, 0xA5
    sw   t0, 8(s11)
    li   t1, 'R'
    PUTC t1
    li   t0, 0x7777
    sw   t0, 0(s11)
1:  j    1b

boot3:
    HEADER 'C'
stop:
    li   t1, 'Z'
    PUTC t1
1:  j    1b
