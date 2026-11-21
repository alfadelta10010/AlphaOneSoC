/* T1: the 16550A, polled. Loopback keeps the checks off the pin; the rest of the transcript is the
   TX path (8N1 timing is checked by whatever captures the pin). No core interrupts: IIR is read and
   the PLIC pending word is polled. */
#include "hw.h"

#define CHAR_CLK (160u * DIVISOR)       /* one 8N1 character, in core clocks */

static void wait_ticks(u32 n) { u32 t0 = mtime(); while ((u32)(mtime() - t0) < n) ; }
static void wait_chars(u32 n) { while (n--) wait_ticks(CHAR_CLK); }

/* PLIC source 1 = the UART. Claim, complete, and leave it not pending. */
static void plic_clear(void) {
    R32(0x0C200004u);                    /* claim (clears pending, sets in-service) */
    R32(0x0C200004u) = 1;                /* complete */
    wait_ticks(8);
}
static u32 plic_pend(void) { return R32(PLIC_PEND) & 2u; }

static void send(u8 c) { R8(U_THR) = c; }

void t_uart(void) {
    static const u8 trig[4] = {1, 2, 4, 7};
    u32 code, i, n;
    t_begin("uart");

    chk(g_mcr0, 0x02, "MCR reset value");
    uart_drain();
    chk(R8(U_LSR), 0x60, "LSR idle THRE|TEMT");
    chk(R8(U_IIR), 0xC1, "IIR idle, FIFOs on");
    chk(R8(U_MSR), 0xB0, "MSR not loopback");

    /* SCR, IER */
    R8(U_SCR) = 0x55; chk(R8(U_SCR), 0x55, "SCR 55");
    R8(U_SCR) = 0xAA; chk(R8(U_SCR), 0xAA, "SCR AA");
    R8(U_SCR) = 0x00; chk(R8(U_SCR), 0x00, "SCR 00");
    R8(U_IER) = 0x0F; chk(R8(U_IER), 0x0F, "IER 0F");
    R8(U_IER) = 0x00; chk(R8(U_IER), 0x00, "IER 00");

    /* LCR / DLAB / divisor */
    uart_drain();
    R8(U_LCR) = 0x83; chk(R8(U_LCR), 0x80, "LCR 83 reads DLAB only");
    R8(U_DLL) = 0x5A; chk(R8(U_DLL), 0x5A, "DLL 5A");
    R8(U_DLM) = 0xA5; chk(R8(U_DLM), 0xA5, "DLM A5");
    R8(U_DLL) = DIVISOR & 0xFF; R8(U_DLM) = DIVISOR >> 8;
    chk(R8(U_DLL), DIVISOR & 0xFF, "DLL divisor");
    chk(R8(U_DLM), DIVISOR >> 8, "DLM divisor");
    R8(U_LCR) = 0x03; chk(R8(U_LCR), 0x00, "LCR 03 reads 0 (frame is fixed)");
    chk(R8(U_IER), 0x00, "IER back at offset 1");

    /* MCR and the loopback MSR */
    R8(U_MCR) = 0x1F; chk(R8(U_MCR), 0x1F, "MCR 1F");
    chk(R8(U_MSR), 0xF0, "MSR loop OUT2 OUT1 DTR RTS");
    R8(U_MCR) = 0x12; chk(R8(U_MSR), 0x10, "MSR loop RTS");
    R8(U_MCR) = 0x11; chk(R8(U_MSR), 0x20, "MSR loop DTR");
    R8(U_MCR) = 0x14; chk(R8(U_MSR), 0x40, "MSR loop OUT1");
    R8(U_MCR) = 0x18; chk(R8(U_MSR), 0x80, "MSR loop OUT2");

    /* Loopback data, one pass per RX trigger level (1, 2, 4, 7 bytes) */
    R8(U_MCR) = 0x12;
    R32(0x0C000004u) = 1;                /* PLIC priority of source 1 */
    R32(0x0C002000u) = 2;                /* enable source 1 */
    R32(0x0C200000u) = 0;                /* threshold 0 */
    for (code = 0; code < 4; code++) {
        n = trig[code];
        R8(U_FCR) = 0x07 | (code << 6);
        R8(U_IER) = 0x01;
        plic_clear();
        chk(plic_pend(), 0, "PLIC pending clear before the burst");
        for (i = 0; i + 1 < n; i++) send(0xA0 + i);
        uart_drain(); wait_chars(1);
        if (n > 1) {
            chk(R8(U_IIR), 0xC1, "IIR below trigger");
            chk(plic_pend(), 0, "PLIC pending below trigger");
            chk(R8(U_LSR) & 1, 1, "LSR DR below trigger");
        }
        send(0xA0 + n - 1);
        uart_drain(); wait_chars(1);
        chk(R8(U_IIR), 0xC4, "IIR RDA at trigger");
        chk(plic_pend(), 2, "PLIC pending at trigger");
        chk(R8(U_LSR) & 0x61, 0x61, "LSR TEMT THRE DR");
        for (i = 0; i < n; i++) chk(R8(U_RBR), 0xA0 + i, "RBR byte");
        chk(R8(U_LSR) & 1, 0, "LSR DR after drain");
        chk(R8(U_IIR), 0xC1, "IIR after drain");
        plic_clear();
        chk(plic_pend(), 0, "PLIC pending after claim");
    }

    /* Character timeout: one byte below a 4-byte trigger, nobody reads it */
    R8(U_FCR) = 0x07 | (2 << 6);
    R8(U_IER) = 0x01;
    send(0x3C);
    uart_drain(); wait_chars(1);
    chk(R8(U_IIR), 0xC1, "IIR before the timeout");
    wait_chars(6);
    chk(R8(U_IIR), 0xCC, "IIR character timeout");
    chk(R8(U_RBR), 0x3C, "RBR timeout byte");
    chk(R8(U_IIR), 0xC1, "IIR after the timeout byte");
    plic_clear();

    /* THRE interrupt code: a level */
    R8(U_IER) = 0x02;
    chk(R8(U_IIR), 0xC2, "IIR THRE");
    chk(R8(U_IIR), 0xC2, "IIR THRE again (a level)");
    R8(U_IER) = 0x00;
    chk(R8(U_IIR), 0xC1, "IIR none, IER 0");
    plic_clear();

    /* LSR THRE / TEMT around a transmit, and the received byte */
    R8(U_FCR) = 0x07;
    uart_drain();
    send(0x69);
    chk(R8(U_LSR) & 0x40, 0, "LSR TEMT low while shifting");
    uart_drain(); wait_chars(1);
    chk(R8(U_LSR), 0x61, "LSR idle with a byte waiting");
    chk(R8(U_RBR), 0x69, "RBR loopback byte");
    chk(R8(U_LSR), 0x60, "LSR idle");

    /* Leave the port as the program found it */
    R8(U_MCR) = 0x02;
    R8(U_IER) = 0x00;
    R8(U_FCR) = 0x07;
    R32(0x0C002000u) = 0;
    R32(0x0C000004u) = 0;
    chk(R8(U_MSR), 0xB0, "MSR after loopback");
    t_end();
}
