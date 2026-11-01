#include "soc.h"

void exit(int code)
{
    if (code == 0)
        soc_pass();
    soc_fail(code & 0xFFFF);
}

void _exit(int code) { exit(code); }
