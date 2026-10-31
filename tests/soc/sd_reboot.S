# A reboot in the middle of an SD block read (WO-29 8, WO-28 2.3, 2.5): the card
# is initialised, CMD17 is issued at BAUD 255 (a byte is 4096 clocks, each SCK
# level 256), and a byte is started and FINISH 0x7777 is written after RB_DLY
# clocks so that the reboot lands in the A phase or the B phase of a bit. After
# the reboot the second boot checks RESET_CAUSE (PIN | SOFT) and OUT = 0x89, clears
# SOFT and passes. The bench checks the phase the reboot hit, the pins during the
# hold and after it, n_race (1 in A in mode 3, 0 in B) and that no SCK edge
# follows with the card selected.
#include "periph.h"
#include "spi_drv.S"
#ifndef RB_DLY
#define RB_DLY 700
#endif
    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s1, GPIO
    lw   s0, 4(s11)                    /* RESET_CAUSE */
    li   t0, 1
    beq  s0, t0, boot1
    li   t0, 3
    beq  s0, t0, boot2
    li   a6, 0x100
    mv   a7, s0
    j    test_fail
boot1:
    li   s5, 0
    li   s6, 0
    jal  ra, crc_init
    SD_CARD_INIT 255
    SD_CMD17 5
    EVENT 0x41                         /* about to start the byte the reboot cuts */
    li   t2, 0xFF
    sb   t2, S_TXDATA(s1)
    DELAY RB_DLY
    li   t0, 0x7777
    sw   t0, MB_FINISH(s11)
1:  j    1b
boot2:
    lw   t0, G_OUT(s1)
    CHECK t0, 0x89, 0x201              /* the reset pins */
    li   t0, 2
    sw   t0, 4(s11)                    /* W1C SOFT */
    j    test_pass
    EPILOGUE
