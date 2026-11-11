/* Polled UART output and input, and the syscon finish. */
#include "soc.h"

void uart_init(unsigned divisor)
{
    *reg8(UART_BASE + UART_LCR) = UART_LCR_DLAB;
    *reg8(UART_BASE + UART_DLL) = divisor & 0xFF;
    *reg8(UART_BASE + UART_DLM) = divisor >> 8;
    *reg8(UART_BASE + UART_LCR) = 0;
}

void uart_putc(int c)
{
    while (!(*reg8(UART_BASE + UART_LSR) & UART_LSR_THRE))
        ;
    *reg8(UART_BASE + UART_THR) = (uint8_t)c;
}

int uart_rx_ready(void)
{
    return *reg8(UART_BASE + UART_LSR) & UART_LSR_DR;
}

int uart_getc(void)
{
    while (!uart_rx_ready())
        ;
    return *reg8(UART_BASE + UART_RBR);
}

/* Wait until the last character has left the shifter. */
void uart_flush(void)
{
    while (!(*reg8(UART_BASE + UART_LSR) & UART_LSR_TEMT))
        ;
}

void uart_puts(const char *s)
{
    for (; *s; s++) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s);
    }
}

void uart_puthex(uint32_t v, int digits)
{
    for (int i = digits - 1; i >= 0; i--)
        uart_putc("0123456789abcdef"[(v >> (4 * i)) & 0xF]);
}

void uart_putdec(uint32_t v)
{
    char b[10];
    int n = 0;
    do { b[n++] = '0' + v % 10; v /= 10; } while (v);
    while (n)
        uart_putc(b[--n]);
}

void soc_finish(uint32_t code)
{
    uart_flush();
    *reg32(SYSCON_BASE + SYSCON_FINISH) = code;
    for (;;)
        ;
}
