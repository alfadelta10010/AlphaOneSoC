# The UART accesses Linux's 8250 driver makes on this chip, in order, with
# the values it would read checked (drivers/tty/serial/8250/: 8250_early.c,
# 8250_port.c). The device tree says ns16550a with no interrupts, so the
# driver polls: a timer calls the interrupt handler, which reads IIR first
# and returns if bit 0 (no interrupt) is set.
#
#  1. earlycon: init_port() -- LCR, IER, FCR, MCR, then the divisor with a
#     read-modify-write of LCR -- and serial_putc() for each character: THR,
#     then poll LSR until both THRE and TEMT (BOTH_EMPTY).
#  2. serial8250_do_startup(): clear the FIFOs through FCR; read LSR, RX,
#     IIR, MSR; the LSR != 0xff check; LCR = 8N1; MCR; the TX-enable test
#     (IER = THRI, read LSR and IIR: TEMT with IIR's no-interrupt bit set
#     would turn on UART_BUG_TXEN); read LSR, RX, IIR, MSR again.
#  3. serial8250_do_set_termios(): IER, the divisor under DLAB (a new one:
#     cue 4 tells the terminal), LCR, FCR twice, MCR.
#  4. Transmit through start_tx and the polled handler: IER |= THRI; each
#     poll reads IIR, then LSR and MSR, and when THRE is set and THRI is
#     enabled serial8250_tx_chars() writes up to tx_loadsz = 16 characters
#     to THR back to back -- the UART's back-pressure paces them -- and
#     __stop_tx() clears THRI when the buffer is empty. A poll made while a
#     character is still on the line sees IIR = no interrupt.
#  5. Receive through the same handler: the terminal types a line (cue 5,
#     CTS flow control on); IIR = RX data; serial8250_rx_chars() reads RX
#     while LSR.DR. One character arrives per poll: RTS# holds the next.
#  6. serial8250_console_write(): save IER, clear it, write each character
#     after polling THRE (uart_console_write, with '\r' before '\n'), wait
#     for BOTH_EMPTY, restore IER. Then the FIFO variant
#     (serial8250_console_fifo_write): wait for THRE once, write up to 16.
#include "periph.h"

#define NEW_DIV 3

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s0, UART

    # ---- 1. earlycon: init_port() ----
    li   t0, 0x03
    sb   t0, LCR(s0)             # 8N1
    lbu  t0, IER(s0)             # ier = IER
    CHECK t0, 0x00, 0x101
    andi t0, t0, 0x40            # IER = ier & UART_IER_UUE
    sb   t0, IER(s0)
    sb   zero, FCR(s0)           # FCR = 0
    li   t0, 0x03
    sb   t0, MCR(s0)             # DTR | RTS
    lbu  t1, LCR(s0)             # c = LCR
    CHECK t1, 0x00, 0x102        # only DLAB is kept
    ori  t0, t1, 0x80
    sb   t0, LCR(s0)             # c | DLAB
    li   t0, 4                   # DIV_ROUND_CLOSEST(uartclk, 16 * baud)
    sb   t0, DLL(s0)
    sb   zero, DLM(s0)
    andi t0, t1, 0x7f
    sb   t0, LCR(s0)             # c & ~DLAB
    la   a0, s_early
    jal  early_puts

    # ---- 2. serial8250_do_startup() ----
    li   t0, 0x01
    sb   t0, FCR(s0)             # serial8250_clear_fifos: ENABLE_FIFO
    li   t0, 0x07
    sb   t0, FCR(s0)             #   | CLEAR_RCVR | CLEAR_XMIT
    sb   zero, FCR(s0)           #   then 0
    lbu  t0, LSR(s0)             # "Clear the interrupt registers"
    lbu  t0, RBR(s0)
    lbu  t0, IIR(s0)
    CHECK t0, 0x01, 0x110
    lbu  t0, MSR(s0)
    CHECK t0, 0xB0, 0x111
    lbu  t0, LSR(s0)             # the LSR != 0xff safety check
    CHECK t0, 0x60, 0x112
    li   t0, 0x03
    sb   t0, LCR(s0)             # UART_LCR_WLEN8
    li   t0, 0x03
    sb   t0, MCR(s0)             # serial8250_set_mctrl
    li   t0, 0x02
    sb   t0, IER(s0)             # TX-enable test: IER = THRI
    lbu  t1, LSR(s0)
    lbu  t2, IIR(s0)
    sb   zero, IER(s0)
    CHECK t1, 0x60, 0x113        # TEMT ...
    CHECK t2, 0x02, 0x114        # ... and THRI pending: no UART_BUG_TXEN
    lbu  t0, LSR(s0)             # "Clear the interrupt registers again"
    lbu  t0, RBR(s0)
    lbu  t0, IIR(s0)
    lbu  t0, MSR(s0)
    li   s1, 0x05                # up->ier = UART_IER_RLSI | UART_IER_RDI

    # ---- 3. serial8250_do_set_termios() ----
    sb   s1, IER(s0)
#ifdef MB_UART
    EVENT_P 4                    # the terminal follows the new baud rate: before the write
#endif
    li   t0, 0x83
    sb   t0, LCR(s0)             # serial8250_do_set_divisor: lcr | DLAB
    li   t0, NEW_DIV
    sb   t0, DLL(s0)             # serial_dl_write
    sb   zero, DLM(s0)
    li   t0, 0x03
    sb   t0, LCR(s0)             # "reset DLAB"
    li   t0, 0x01
    sb   t0, FCR(s0)             # two steps, for emulated UARTs
    li   t0, 0x81
    sb   t0, FCR(s0)             # up->fcr: ENABLE_FIFO | R_TRIG_10
    li   t0, 0x03
    sb   t0, MCR(s0)
    lbu  t0, IER(s0)
    CHECK t0, 0x01, 0x120        # RDI kept; RLSI does not exist here
    li   t0, 0x80
    sb   t0, LCR(s0)
    lbu  t0, DLL(s0)
    CHECK t0, NEW_DIV, 0x121
    lbu  t0, DLM(s0)
    CHECK t0, 0, 0x122
    sb   zero, LCR(s0)
#ifndef MB_UART
    EVENT 4                      # the terminal follows the new baud rate
#endif

    # ---- 4. start_tx() and the polled handler ----
    la   s2, s_tx
    ori  s1, s1, 0x02            # serial8250_set_THRI
    sb   s1, IER(s0)
    li   s4, 0                   # polls that found IIR = no interrupt
    li   s5, 0                   # tx_chars bursts
poll_tx:
    lbu  t0, IIR(s0)             # serial8250_default_handle_irq
    andi t1, t0, 0x01
    bnez t1, 5f
    CHECK t0, 0x02, 0x130        # only THRI can be pending here
    lbu  t1, LSR(s0)             # serial_lsr_in
    andi t2, t1, LSR_DR | LSR_OE
    beqz t2, 1f
    mv   a7, t1
    li   a6, 0x131               # nothing is being sent to us yet
    j    test_fail
1:  lbu  t2, MSR(s0)             # serial8250_modem_status
    CHECK t2, 0xB0, 0x132
    andi t2, t1, LSR_THRE        # (lsr & THRE) && (ier & THRI)
    beqz t2, 6f
    andi t2, s1, 0x02
    beqz t2, 6f
    addi s5, s5, 1               # serial8250_tx_chars
    li   t3, 16                  # up->tx_loadsz
2:  lbu  t0, 0(s2)
    beqz t0, 3f
    sb   t0, THR(s0)             # back to back: the UART paces them
    addi s2, s2, 1
    addi t3, t3, -1
    bnez t3, 2b
3:  lbu  t0, 0(s2)
    bnez t0, poll_tx             # more to send: poll again at once, while the
                                 # last character is still on the line
    andi s1, s1, ~0x02           # __stop_tx: clear THRI
    sb   s1, IER(s0)
    j    7f
5:  addi s4, s4, 1
6:  li   t0, 8                   # until the next timer tick
4:  addi t0, t0, -1
    bnez t0, 4b
    j    poll_tx
7:  VALUE s5
    CHECK s5, 4, 0x133           # 55 characters: 16 + 16 + 16 + 7
    beqz s4, 8f
    j    9f
8:  mv   a7, s4
    li   a6, 0x134               # never polled while TX was busy
    j    test_fail
9:  WAIT_LSR s0, LSR_TEMT
    lbu  t0, IIR(s0)
    CHECK t0, 0x01, 0x135        # THRI off, nothing received

    # ---- 5. receive: serial8250_rx_chars() from the polled handler ----
    EVENT_P 5                      # the terminal types s_rx, CTS flow control on
    li   s6, 0x80000100          # the tty flip buffer
    li   s7, 0                   # characters received
poll_rx:
    lbu  t0, IIR(s0)
    andi t1, t0, 0x01
    bnez t1, 3f
    CHECK t0, 0x04, 0x140        # RX data available
    lbu  t1, LSR(s0)
    li   t3, 256                 # max_count
1:  andi t2, t1, LSR_OE
    beqz t2, 2f
    mv   a7, t1
    li   a6, 0x141               # overrun with flow control on
    j    test_fail
2:  andi t2, t1, LSR_DR          # serial8250_read_char
    beqz t2, 4f
    lbu  t0, RBR(s0)
    sb   t0, 0(s6)
    addi s6, s6, 1
    addi s7, s7, 1
4:  addi t3, t3, -1
    beqz t3, 5f
    lbu  t1, LSR(s0)             # while (lsr & (DR | BI))
    andi t2, t1, LSR_DR
    bnez t2, 1b
5:  lbu  t0, MSR(s0)
3:  la   t0, s_rx_end
    la   t1, s_rx
    sub  t0, t0, t1
    bge  s7, t0, 6f
    li   t0, 8
7:  addi t0, t0, -1
    bnez t0, 7b
    j    poll_rx
6:  la   t0, s_rx_end
    la   t1, s_rx
    sub  t0, t0, t1
    CHECKR s7, t0, 0x142
    la   a0, s_rx                # what arrived is what was typed
    li   a1, 0x80000100
    mv   a2, s7
1:  lbu  t0, 0(a0)
    lbu  t1, 0(a1)
    CHECKR t1, t0, 0x143
    addi a0, a0, 1
    addi a1, a1, 1
    addi a2, a2, -1
    bnez a2, 1b

    # ---- 6. serial8250_console_write() ----
    lbu  s8, IER(s0)             # save IER
    CHECK s8, 0x01, 0x150
    sb   zero, IER(s0)           # serial8250_clear_IER
    la   a0, s_con
1:  lbu  a1, 0(a0)
    beqz a1, 2f
    li   t0, '\n'
    bne  a1, t0, 3f
    li   a2, '\r'                # uart_console_write: '\r' before '\n'
    jal  con_putchar
3:  mv   a2, a1
    jal  con_putchar
    addi a0, a0, 1
    j    1b
2:  WAIT_LSR s0, 0x60            # wait_for_xmitr(BOTH_EMPTY)
    sb   s8, IER(s0)             # restore IER
    # serial8250_console_fifo_write(): THRE once, then up to 16 characters
    sb   zero, IER(s0)
    la   a0, s_con2
    li   s9, 0                   # cr_sent
4:  WAIT_LSR s0, LSR_THRE
    li   t3, 16
5:  lbu  a1, 0(a0)
    beqz a1, 7f
    li   t0, '\n'
    bne  a1, t0, 6f
    bnez s9, 6f
    li   t0, '\r'
    sb   t0, THR(s0)
    li   s9, 1
    j    8f
6:  sb   a1, THR(s0)
    li   s9, 0
    addi a0, a0, 1
8:  addi t3, t3, -1
    bnez t3, 5b
    j    4b
7:  WAIT_LSR s0, 0x60
    sb   s8, IER(s0)
    j    test_pass

# serial_putc() of 8250_early.c: THR, then wait for BOTH_EMPTY.
early_puts:
1:  lbu  t0, 0(a0)
    beqz t0, 2f
    sb   t0, THR(s0)
    WAIT_LSR s0, 0x60
    addi a0, a0, 1
    j    1b
2:  ret

# serial8250_console_putchar(): wait_for_xmitr(THRE), then THR.
con_putchar:
    WAIT_LSR s0, LSR_THRE
    sb   a2, THR(s0)
    ret

    EPILOGUE

    .section .rodata
s_early: .asciz "earlycon: AlphaOne\r\n"
s_tx:    .asciz "tx_chars 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEF\r\n"
s_rx:    .ascii "ls -l /dev\r"
s_rx_end:
         .byte 0
s_con:   .asciz "console: polled\n"
s_con2:  .asciz "console: fifo path, 16 at a time\n"
