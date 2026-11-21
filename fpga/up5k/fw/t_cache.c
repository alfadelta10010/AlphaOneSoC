/* T4: the instruction cache (CACHE_CTL at syscon +0x24: [0] EN, [1] reads 1). A loop in flash must give
   the same results with the cache off and on (the speed-up is INFO, from mtime). Store snoop: a function
   is copied to PSRAM and run, then overwritten (whole function, one word, one byte) and run again;
   the new code must run. picorv32 has no fence.i, so this is the coherence path the cache documents. */
#include "hw.h"
#define BARRIER() __asm__ volatile("" ::: "memory")

extern const u32 fn_a[], fn_a_end[], fn_b[], fn_b_end[];

/* the timed loop: stays in flash; 64 iterations of a small body with a branch and a few ALU ops */
static u32 __attribute__((noipa)) kernel(u32 n) {   /* noipa: not pure-folded, not moved across the mtime reads */
    u32 acc = 0x1234u, i;
    for (i = 0; i < n; i++) {
        acc ^= i;
        acc += (acc << 3) ^ (acc >> 5);
        if (acc & 1) acc ^= 0xA5A5u;
    }
    return acc;
}
static const u32 loop_n_init = 2000;   /* a const: no .data to initialise */
#define loop_n (*(volatile const u32 *)&loop_n_init)   /* volatile read: the compiler must not fold the timed calls */

typedef u32 (*fn_t)(u32);

static u32 call(u32 addr, u32 x) { return ((fn_t)addr)(x); }

#define CODE (PSRAM_A + 0x30000u)    /* outside the memory test window */

static void copy(u32 dst, const u32 *src, const u32 *end) {
    u32 i = 0;
    while (src + i < end) { R32(dst + (i << 2)) = src[i]; i++; }
}

void t_cache(void) {
    u32 t0, t_off, t_on, r_off, r_on, r;
    t_begin("cache");

    chk(R32(CACHE_CTL), 2, "CACHE_CTL reset: EN 0, built 1");
    BARRIER(); t0 = mtime(); BARRIER(); r_off = kernel(loop_n); BARRIER(); t_off = mtime() - t0;
    R32(CACHE_CTL) = 1;
    chk(R32(CACHE_CTL), 3, "CACHE_CTL EN set");
    r_on = kernel(loop_n);                      /* cold */
    BARRIER(); t0 = mtime(); BARRIER(); r_on = kernel(loop_n); BARRIER(); t_on = mtime() - t0;
    chk(r_on, r_off, "loop result, cache on == cache off");
        puts_("INFO cache loop ticks off="); putd(t_off); puts_(" on="); putd(t_on); puts_("\n");

    /* Snoop. Code in PSRAM: run it twice (the second is a hit), then replace it. */
    copy(CODE, fn_a, fn_a_end);
    chk(call(CODE, 5), 5 + 0x111, "fn_a from PSRAM, cache on");
    chk(call(CODE, 6), 6 + 0x111, "fn_a again (hit)");
    copy(CODE, fn_b, fn_b_end);               /* whole function overwritten */
    chk(call(CODE, 5), 5 + 0x222, "fn_b after overwrite: the snoop invalidated the line");
    chk(call(CODE, 7), 7 + 0x222, "fn_b again");
    /* one word: back to fn_a's first word only */
    R32(CODE) = fn_a[0];
    chk(call(CODE, 9), 9 + 0x111, "one word patched");
    chk(call(CODE, 9), 9 + 0x111, "one word patched, again");
    /* one byte: byte 3 of the addi is imm[11:4]; 0x111 -> 0x131 with 0x13 */
    R8(CODE + 3) = 0x13;
    r = call(CODE, 1);
    chk(r, 1 + 0x131, "one byte patched");
    /* one halfword: the upper half of the addi is imm[11:0] and rs1[0]: restore fn_b's */
    *(volatile u16 *)(CODE + 2) = (u16)(fn_b[0] >> 16);
    chk(call(CODE, 2), 2 + 0x222, "one halfword patched");

    /* cache off again, the old code must still be what is in memory */
    R32(CACHE_CTL) = 0;
    chk(R32(CACHE_CTL), 2, "CACHE_CTL EN cleared");
    chk(call(CODE, 3), 3 + 0x222, "from PSRAM, cache off");
    R32(CODE) = fn_a[0];
    chk(call(CODE, 3), 3 + 0x111, "patched, cache off");
    chk(kernel(loop_n), r_off, "loop result, cache off again");
    t_end();
}
