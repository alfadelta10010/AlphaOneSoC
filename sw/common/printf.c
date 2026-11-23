/* A small printf for the benchmarks and the UART console: %d %i %u %x %X %c %s %p %%,
 * the l modifier (long is 32 bits here), flags '0' and '-', a width. No floating
 * point, no stdio buffers, nothing from newlib's stdio (which would pull in
 * malloc and the reent structure). '\n' is sent as CR LF, as uart_puts does. */
#include <stdarg.h>
#include "soc.h"

static int pad(int n, int width, char fill)
{
    int out = 0;
    for (; n < width; n++, out++)
        uart_putc(fill);
    return out;
}

int vprintf(const char *fmt, va_list ap)
{
    int count = 0;
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            if (*fmt == '\n') { uart_putc('\r'); count++; }
            uart_putc(*fmt);
            count++;
            continue;
        }
        fmt++;
        int left = 0, zero = 0, width = 0;
        for (;; fmt++) {
            if (*fmt == '-') left = 1;
            else if (*fmt == '0') zero = 1;
            else break;
        }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l' || *fmt == 'h' || *fmt == 'z')
            fmt++;
        char buf[12];
        const char *s = buf;
        int n = 0, neg = 0;
        switch (*fmt) {
        case 'd': case 'i': {
            int32_t v = va_arg(ap, int32_t);
            uint32_t u = v;
            if (v < 0) { neg = 1; u = -u; }
            do { buf[n++] = '0' + u % 10; u /= 10; } while (u);
            break;
        }
        case 'u': {
            uint32_t u = va_arg(ap, uint32_t);
            do { buf[n++] = '0' + u % 10; u /= 10; } while (u);
            break;
        }
        case 'x': case 'X': case 'p': {
            uint32_t u = va_arg(ap, uint32_t);
            const char *dig = *fmt == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
            do { buf[n++] = dig[u & 0xF]; u >>= 4; } while (u);
            break;
        }
        case 'c':
            buf[0] = (char)va_arg(ap, int);
            n = 1;
            break;
        case 's':
            s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            for (n = 0; s[n]; n++)
                ;
            break;
        case '%':
            buf[0] = '%';
            n = 1;
            break;
        default:
            return count;   /* unknown conversion: stop rather than guess */
        }
        int len = n + neg;
        int is_str = *fmt == 's' || *fmt == 'c' || *fmt == '%';
        char fill = (zero && !is_str) ? '0' : ' ';
        if (!left && fill == ' ')
            count += pad(len, width, ' ');
        if (neg) { uart_putc('-'); count++; }
        if (!left && fill == '0')
            count += pad(len, width, '0');
        if (is_str) {
            for (int i = 0; i < n; i++) uart_putc(s[i]);
        } else {
            for (int i = n; i > 0; i--) uart_putc(buf[i - 1]);
        }
        count += n;
        if (left)
            count += pad(len, width, ' ');
    }
    return count;
}

int printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = vprintf(fmt, ap);
    va_end(ap);
    return n;
}

int ee_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = vprintf(fmt, ap);
    va_end(ap);
    return n;
}

void debug_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}

int putchar(int c)
{
    if (c == '\n')
        uart_putc('\r');
    uart_putc(c);
    return c;
}

int puts(const char *s)
{
    uart_puts(s);
    uart_putc('\r');
    uart_putc('\n');
    return 1;
}
