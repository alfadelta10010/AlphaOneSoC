/* Polled console for AlphaOneSoC: a 16550 subset at 0x1000_0000 with byte
 * registers, no FIFO and no interrupt line.  The serial upper half is driven
 * from here: transmit directly when the upper half enables the TX
 * "interrupt", receive from the idle loop (up_idle) and from the tick.
 */

#include <nuttx/config.h>

#include <stdint.h>
#include <stdbool.h>
#include <errno.h>

#include <nuttx/arch.h>
#include <nuttx/irq.h>
#include <nuttx/serial/serial.h>

#include "riscv_internal.h"

#define ALPHA_UART_BASE 0x10000000
#define ALPHA_UART_RBR  (*(volatile uint8_t *)(ALPHA_UART_BASE + 0))
#define ALPHA_UART_THR  (*(volatile uint8_t *)(ALPHA_UART_BASE + 0))
#define ALPHA_UART_LSR  (*(volatile uint8_t *)(ALPHA_UART_BASE + 5))
#define LSR_DR          0x01
#define LSR_THRE        0x20

static char g_rxbuf[128];
static char g_txbuf[256];
static volatile bool g_rxint;

static int  au_setup(struct uart_dev_s *dev)    { return OK; }
static void au_shutdown(struct uart_dev_s *dev) { }
static int  au_attach(struct uart_dev_s *dev)   { return OK; }
static void au_detach(struct uart_dev_s *dev)   { }
static int  au_ioctl(struct file *filep, int cmd, unsigned long arg)
{
  return -ENOTTY;
}

static int au_receive(struct uart_dev_s *dev, unsigned int *status)
{
  *status = 0;
  return ALPHA_UART_RBR;
}

static void au_rxint(struct uart_dev_s *dev, bool enable)
{
  g_rxint = enable;
}

static bool au_rxavailable(struct uart_dev_s *dev)
{
  return (ALPHA_UART_LSR & LSR_DR) != 0;
}

static void au_send(struct uart_dev_s *dev, int ch)
{
  ALPHA_UART_THR = (uint8_t)ch;
}

static void au_txint(struct uart_dev_s *dev, bool enable)
{
  /* No interrupt line: when the upper half asks for the TX interrupt, run
   * the transmit loop now (the THR write itself waits for the shifter).
   */

  if (enable)
    {
      uart_xmitchars(dev);
    }
}

static bool au_txready(struct uart_dev_s *dev)
{
  /* Always ready: a THR write while the shifter is busy holds the bus until
   * the frame in flight has gone (src/uart.v), so a loop of sends is paced
   * by the hardware.
   */

  return true;
}

static bool au_txempty(struct uart_dev_s *dev)
{
  return (ALPHA_UART_LSR & LSR_THRE) != 0;
}

static const struct uart_ops_s g_ops =
{
  .setup       = au_setup,
  .shutdown    = au_shutdown,
  .attach      = au_attach,
  .detach      = au_detach,
  .ioctl       = au_ioctl,
  .receive     = au_receive,
  .rxint       = au_rxint,
  .rxavailable = au_rxavailable,
  .send        = au_send,
  .txint       = au_txint,
  .txready     = au_txready,
  .txempty     = au_txempty,
};

static struct uart_dev_s g_dev =
{
  .isconsole = true,
  .recv      = { .size = sizeof(g_rxbuf), .buffer = g_rxbuf },
  .xmit      = { .size = sizeof(g_txbuf), .buffer = g_txbuf },
  .ops       = &g_ops,
};

void alpha_uart_poll(void)
{
  if (g_rxint && (ALPHA_UART_LSR & LSR_DR) != 0)
    {
      irqstate_t flags = up_irq_save();
      uart_recvchars(&g_dev);
      up_irq_restore(flags);
    }
}

void up_idle(void)
{
  /* No WFI: the receiver is polled, and a wake-up per tick would cost one
   * 10 ms tick per typed character.
   */

  alpha_uart_poll();
}

void alpha_uart_earlyinit(void)
{
}

void alpha_uart_init(void)
{
  uart_register("/dev/console", &g_dev);
  uart_register("/dev/ttyS0", &g_dev);
}

void up_putc(int ch)
{
  while ((ALPHA_UART_LSR & LSR_THRE) == 0)
    {
    }

  if (ch == '\n')
    {
      ALPHA_UART_THR = '\r';
      while ((ALPHA_UART_LSR & LSR_THRE) == 0)
        {
        }
    }

  ALPHA_UART_THR = (uint8_t)ch;
}
