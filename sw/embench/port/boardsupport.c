/* Embench-IoT board support for AlphaOneSoC: the triggers read mtime, which
 * counts core clocks, so a benchmark's time is exact in clocks. The result
 * goes out on the UART from exit() (common/exit.c), after the benchmark's
 * own verification has run. Embench's rule: time only the region between
 * start_trigger and stop_trigger, with a counter running faster than the
 * benchmark. */
#include <support.h>
#include "soc.h"

#ifndef BENCH_NAME
#define BENCH_NAME "unknown"
#endif

static uint64_t t_start, t_stop;

void initialise_board(void) { }
void start_trigger(void) { t_start = mtime_read(); }
void stop_trigger(void)  { t_stop = mtime_read(); }

void bench_report(int code)
{
    uint64_t clocks = t_stop - t_start;
    uart_puts("EMBENCH " BENCH_NAME " clocks=");
    uart_putdec((uint32_t)clocks);
    uart_puts(code == 0 ? " correct=1\n" : " correct=0\n");
}
