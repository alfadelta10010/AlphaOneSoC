#include "soc.h"

/* A benchmark's board support reports its result here, after main returns. */
__attribute__((weak)) void bench_report(int code) { (void)code; }

void exit(int code)
{
    bench_report(code);
    if (code == 0)
        soc_pass();
    soc_fail(code & 0xFFFF);
}

void _exit(int code) { exit(code); }
