# Every pin of the TinyTapeout top level, from the outside (tb/tb_tt_um.v).
# The program reports through the UART and nothing else, so the same run
# works on a netlist that has no core data port to watch: no mailbox here.
#
#  1. GPIO OUT. Each of out_vals goes to OUT, then an 'o' leaves on TX. The
#     testbench reads uo_out[7:6] and uo_out[3:0] as each 'o' arrives.
#  2. GPIO IN and UART RX. After each 'i' the testbench puts a pattern on
#     ui_in and sends a byte. The program waits for it, reads IN, and sends
#     back the byte and then IN.
#  3. The chip selects. 'a', a store and a load in PSRAM A; 'b', the same in
#     PSRAM B; 'c'. The testbench counts the falls of each chip select pin
#     between the cues and looks for the words in the right PSRAM.
#  4. 'Z'. Any check that fails here sends 'F' instead and stops.
#
# N_OUT and N_IN are the testbench's counts too. The divisor is set to 1,
# 16 clocks a bit, which is the rate the testbench's UART runs at.
#include "periph.h"
#define N_OUT 9
#define N_IN  9

/* Send r and wait until its stop bit has gone (clobbers t4, t5). */
.macro PUTC r
    sb   \r, THR(s0)
    WAIT_LSR s0, LSR_TEMT
.endm

    .section .text.init
    .globl _start
_start:
    li   s0, UART
    li   s1, GPIO
    li   t0, 0x80
    sb   t0, LCR(s0)             # DLAB
    li   t0, 1
    sb   t0, DLL(s0)
    sb   zero, DLM(s0)
    sb   zero, LCR(s0)
    sw   zero, G_CTRL(s1)        # SPI transmitter off: out[1], out[3] are GPIO

    # 1. GPIO OUT
    la   s2, out_vals
    li   s3, N_OUT
1:  lbu  t0, 0(s2)
    sw   t0, G_OUT(s1)
    li   t1, 'o'
    PUTC t1
    addi s2, s2, 1
    addi s3, s3, -1
    bnez s3, 1b

    # 2. GPIO IN and UART RX
    li   s3, N_IN
2:  li   t1, 'i'
    PUTC t1
3:  lbu  t0, LSR(s0)
    andi t0, t0, LSR_DR
    beqz t0, 3b
    lbu  s4, RBR(s0)
    lw   s5, G_IN(s1)
    PUTC s4
    PUTC s5
    addi s3, s3, -1
    bnez s3, 2b

    # 3. The chip selects
    li   t1, 'a'
    PUTC t1
    li   t2, 0x80000100          # PSRAM A
    li   t3, 0x1234ABCD
    sw   t3, 0(t2)
    lw   t6, 0(t2)
    bne  t3, t6, fail
    li   t1, 'b'
    PUTC t1
    li   t2, 0x80800100          # PSRAM B
    li   t3, 0x89EF4567
    sw   t3, 0(t2)
    lw   t6, 0(t2)
    bne  t3, t6, fail
    li   t1, 'c'
    PUTC t1

    # 4. Done
    li   t1, 'Z'
    PUTC t1
4:  j    4b

fail:
    li   t1, 'F'
    PUTC t1
5:  j    5b

    .section .rodata
out_vals:
    .byte 0x01, 0x02, 0x04, 0x08, 0x40, 0x80, 0xFF, 0x00, 0x09
