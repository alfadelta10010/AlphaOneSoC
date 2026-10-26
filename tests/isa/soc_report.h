/* Reporting for programs run through the pins of the TinyTapeout top level
 * (tb/tb_tt_um.v +TEST=isa / +TEST=sig): a UART byte, then a power-off by the
 * syscon. The UART divisor 1 is 16 clocks a bit, the rate of the bench's
 * RP2350 model. Clobbers t0-t2 and the registers a macro names. */
#ifndef SOC_REPORT_H
#define SOC_REPORT_H
#define SOC_UART    0x10000000
#define SOC_GPIO    0x10010000
#define SOC_SYSCON  0x10020000

/* t0 = UART; DLL = 1, DLM = 0, 8 bits, no interrupts */
.macro SOC_UART_INIT
    li   t0, SOC_UART
    li   t1, 0x80
    sb   t1, 3(t0)
    li   t1, 1
    sb   t1, 0(t0)
    sb   zero, 1(t0)
    sb   zero, 3(t0)
.endm
/* send register \r (t0 = UART) and wait for the stop bit (LSR.TEMT) */
.macro SOC_PUTC r
    sb   \r, 0(t0)
1:  lbu  t1, 5(t0)
    andi t1, t1, 0x40
    beqz t1, 1b
.endm
/* the GPIO write waits for the SPI shifter; OUT is written back as it was */
.macro SOC_DRAIN
    li   t1, SOC_GPIO
    lw   t2, 0(t1)
    sw   t2, 0(t1)
.endm
/* FINISH (power-off) with the value in register \r, then wait for it */
.macro SOC_FINISH r
    li   t1, SOC_SYSCON
    sw   \r, 0(t1)
1:  j    1b
.endm
/* riscv-tests: 'P' if gp == 1, else 'F' and gp, little-endian */
.macro SOC_REPORT_GP
    SOC_UART_INIT
    li   t2, 1
    bne  gp, t2, 2f
    li   a0, 'P'
    SOC_PUTC a0
    li   a4, 0x5555
    j    5f
2:  li   a0, 'F'
    SOC_PUTC a0
    mv   a2, gp
    li   a3, 4
4:  andi a0, a2, 0xff
    SOC_PUTC a0
    srli a2, a2, 8
    addi a3, a3, -1
    bnez a3, 4b
    li   a4, 0x13333
5:  SOC_DRAIN
    SOC_FINISH a4
.endm
/* arch tests: the words from begin_signature to end_signature, raw */
.macro SOC_SIG_DUMP
    la   a2, begin_signature
    la   a3, end_signature
6:  bgeu a2, a3, 7f
    lw   a4, 0(a2)
    li   a6, 4
8:  andi a0, a4, 0xff
    SOC_PUTC a0
    srli a4, a4, 8
    addi a6, a6, -1
    bnez a6, 8b
    addi a2, a2, 4
    j    6b
7:
.endm
#endif
