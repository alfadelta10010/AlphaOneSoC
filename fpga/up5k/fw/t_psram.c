/* T3: PSRAM (QPI, chips A at 0x8000_0000 and B at 0x8080_0000). Stores and loads at every size and
   alignment against a byte model, walking ones/zeros, address-in-address over a 64 KB window, 1 KB page
   and A/B chip crossings, and back-to-back store -> load. The stack sits below the test window. */
#include "hw.h"

#ifndef AIA_STRIDE
#define AIA_STRIDE 1                 /* words between address-in-address probes; 1 = every word */
#endif

static inline u32 xs(u32 x) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x; }

#define MAXN 32
static u8  model[MAXN];
static u32 rng;

/* store and model the store */
static void st8(u32 base, u32 off, u8 v)   { *(volatile u8  *)(base + off) = v; model[off] = v; }
static void st16(u32 base, u32 off, u16 v) { *(volatile u16 *)(base + off) = v; model[off] = (u8)v; model[off+1] = (u8)(v >> 8); }
static void st32(u32 base, u32 off, u32 v) { int i; *(volatile u32 *)(base + off) = v; for (i = 0; i < 4; i++) model[off+i] = (u8)(v >> (8*i)); }

/* every byte with lbu, every aligned word with lw, every aligned halfword with lhu */
static void verify(u32 base, u32 n, const char *what) {
    u32 i, bad = 0, w, wm;
    for (i = 0; i < n; i++) bad |= (u32)(*(volatile u8 *)(base + i)) ^ model[i];
    for (i = 0; i < n; i += 4) {
        w = *(volatile u32 *)(base + i);
        wm = model[i] | ((u32)model[i+1] << 8) | ((u32)model[i+2] << 16) | ((u32)model[i+3] << 24);
        bad |= w ^ wm;
    }
    for (i = 0; i < n; i += 2) bad |= (u32)(*(volatile u16 *)(base + i)) ^ (model[i] | ((u32)model[i+1] << 8));
    chk(bad, 0, what);
}

static void fill(u32 base, u32 n) { u32 i; for (i = 0; i < n; i += 4) st32(base, i, 0xFFFFFFFFu); }

/* a 16-byte area: every byte, every halfword, every word, verified after each store */
static void sizes(u32 base, const char *tag) {
    u32 i, bad;
    fill(base, 16);
    verify(base, 16, tag);
    for (i = 0; i < 16; i++)       { rng = xs(rng); st8(base, i, rng >> 24);    verify(base, 16, tag); }
    for (i = 0; i < 16; i += 2)    { rng = xs(rng); st16(base, i, rng >> 16);   verify(base, 16, tag); }
    for (i = 0; i < 16; i += 4)    { rng = xs(rng); st32(base, i, rng);         verify(base, 16, tag); }
    /* sign extension: store 0x80 / 0x8000 patterns and read with lb / lh / lbu / lhu */
    st32(base, 0, 0x8180FF7Fu); st32(base, 4, 0x80017FFFu);
    bad = 0;
    bad |= (u32)(*(volatile s8 *)(base + 0)) ^ 0x7Fu;
    bad |= (u32)(*(volatile s8 *)(base + 1)) ^ 0xFFFFFFFFu;
    bad |= (u32)(*(volatile s8 *)(base + 2)) ^ 0xFFFFFF80u;
    bad |= (u32)(*(volatile s8 *)(base + 3)) ^ 0xFFFFFF81u;
    bad |= (u32)(*(volatile s16 *)(base + 0)) ^ 0xFFFFFF7Fu;
    bad |= (u32)(*(volatile s16 *)(base + 2)) ^ 0xFFFF8180u;
    bad |= (u32)(*(volatile s16 *)(base + 4)) ^ 0x00007FFFu;
    bad |= (u32)(*(volatile s16 *)(base + 6)) ^ 0xFFFF8001u;
    bad |= (u32)(*(volatile u16 *)(base + 6)) ^ 0x8001u;
    bad |= (u32)(*(volatile u8 *)(base + 3)) ^ 0x81u;
    chk(bad, 0, tag);
}

static void walk(u32 a, const char *tag) {
    u32 b, bad = 0;
    for (b = 0; b < 32; b++) {
        *(volatile u32 *)a = 1u << b;  bad |= *(volatile u32 *)a ^ (1u << b);
        *(volatile u32 *)a = ~(1u << b); bad |= *(volatile u32 *)a ^ ~(1u << b);
    }
    chk(bad, 0, tag);
}

/* a 32-byte area around boundary bd: words, halfwords and bytes on both sides */
static void cross(u32 bd, const char *tag) {
    u32 base = bd - 16;
    fill(base, 32);
    verify(base, 32, tag);
    rng = xs(rng); st32(base, 12, rng);           verify(base, 32, tag);   /* last word below */
    rng = xs(rng); st32(base, 16, rng);           verify(base, 32, tag);   /* first word above */
    rng = xs(rng); st16(base, 14, rng >> 16);     verify(base, 32, tag);
    rng = xs(rng); st16(base, 16, rng >> 16);     verify(base, 32, tag);
    rng = xs(rng); st8(base, 15, rng >> 24);      verify(base, 32, tag);
    rng = xs(rng); st8(base, 16, rng >> 24);      verify(base, 32, tag);
    rng = xs(rng); st32(base, 8, rng); rng = xs(rng); st32(base, 20, rng); verify(base, 32, tag);
}

void t_psram(void) {
    u32 i, bad, a, b, x;
    volatile u32 *w;
    t_begin("psram");
    rng = 0x1234ABCDu;

    sizes(TW_BASE + 0x100,   "sizes A");
    sizes(PSRAM_B + 0x100,   "sizes B");
    walk(TW_BASE + 0x200,    "walking A");
    walk(PSRAM_B + 0x200,    "walking B");

    /* address-in-address over the 64 KB window (chip A), then 4 KB in chip B; A is checked again after B */
    w = (volatile u32 *)TW_BASE;
    for (i = 0; i < 0x4000; i += AIA_STRIDE) w[i] = TW_BASE + (i << 2);
    bad = 0;
    for (i = 0; i < 0x4000; i += AIA_STRIDE) bad |= w[i] ^ (TW_BASE + (i << 2));
    chk(bad, 0, "address-in-address 64KB A");
    w = (volatile u32 *)(PSRAM_B + 0x1000);
    for (i = 0; i < 0x400; i++) w[i] = (PSRAM_B + 0x1000) + (i << 2);
    bad = 0;
    for (i = 0; i < 0x400; i++) bad |= w[i] ^ ((PSRAM_B + 0x1000) + (i << 2));
    chk(bad, 0, "address-in-address 4KB B");
    w = (volatile u32 *)TW_BASE;
    bad = 0;
    for (i = 0; i < 0x4000; i += 61) bad |= w[i] ^ (TW_BASE + (i << 2));   /* A unchanged by B; 61 words apart */
    chk(bad, 0, "A intact after B");

    /* 1 KB page crossings in A and B, and the A/B chip boundary */
    cross(TW_BASE + 0x3400,  "page cross A +0x400");
    cross(TW_BASE + 0x3800,  "page cross A +0x800");
    cross(PSRAM_B + 0x3400,  "page cross B +0x400");
    cross(PSRAM_A + 0x400,   "page cross A low");
    cross(PSRAM_B,           "A/B chip boundary");

    /* back-to-back store -> load, same word, neighbour word, other page, other chip */
    bad = 0; x = 0x5EED0001u;
    for (i = 0; i < 64; i++) {
        u32 va, vb, r1, r2, r3, r4;
        a = TW_BASE + 0x6000 + (i << 2);                   /* chip A */
        b = PSRAM_B + 0x6000 + ((i & 15) << 6) + (i & 4);  /* chip B, different 64 B groups */
        x = xs(x); va = x; x = xs(x); vb = x;
        *(volatile u32 *)a = va; r1 = *(volatile u32 *)a;                          /* same word */
        *(volatile u32 *)b = vb; r2 = *(volatile u32 *)b;
        *(volatile u32 *)a = ~va; *(volatile u32 *)b = ~vb;                        /* A, B, then back */
        r3 = *(volatile u32 *)a; r4 = *(volatile u32 *)b;
        bad |= (r1 ^ va) | (r2 ^ vb) | (r3 ^ ~va) | (r4 ^ ~vb);
        *(volatile u8 *)(a + 1) = 0x5A; r1 = *(volatile u32 *)a;                   /* byte store -> word load */
        bad |= r1 ^ ((~va & 0xFFFF00FFu) | 0x5A00u);
        *(volatile u16 *)(b + 2) = 0xC3A5; r2 = *(volatile u32 *)b;
        bad |= r2 ^ ((~vb & 0x0000FFFFu) | 0xC3A50000u);
    }
    chk(bad, 0, "store then load back to back");
    t_end();
}
