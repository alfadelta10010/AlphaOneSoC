/* CoreMark port for AlphaOneSoC. Derived from CoreMark's `simple` porting
 * layer, Apache License 2.0, Copyright 2018 EEMBC, original author Shay
 * Gal-on.
 *
 * Time is mtime, which counts core clocks, so a result is exact in clocks
 * and independent of the clock frequency the bench or the board runs at.
 * CoreMark's own score line needs a run of 10 s at CLK_HZ (625 million
 * clocks) to be valid; a shorter run prints CoreMark's error for that, and
 * portable_fini adds the figure that does not depend on run length:
 * CoreMark/MHz = iterations * 10^6 / clocks. */
#include "coremark.h"
#include "core_portme.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

#define EE_TICKS_PER_SEC CLK_HZ

static uint64_t start_time_val, stop_time_val;

void start_time(void) { start_time_val = mtime_read(); }
void stop_time(void)  { stop_time_val  = mtime_read(); }

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)(stop_time_val - start_time_val);
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)ticks / (secs_ret)EE_TICKS_PER_SEC;
}

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
#if ITERATIONS > 0
    uint64_t clocks = stop_time_val - start_time_val;
    uint64_t milli = (uint64_t)ITERATIONS * 1000000000ull / clocks;   /* CoreMark/MHz x 1000 */
    ee_printf("Clocks           : %lu\n", (unsigned long)clocks);
    ee_printf("CoreMark/MHz     : %lu.%03lu  (%d iterations; a score needs a 10 s run at %lu Hz)\n",
              (unsigned long)(milli / 1000), (unsigned long)(milli % 1000), ITERATIONS,
              (unsigned long)CLK_HZ);
#endif
}
