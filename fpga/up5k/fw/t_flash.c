/* T2: the flash read path. A pattern region linked into the image (gen_pattern.py) is read back with
   word, halfword and byte loads, and a CRC-32 over it is compared to the CRC of the same xorshift32
   sequence regenerated in registers, so the image itself is never the reference. The whole run is
   repeated for QSPI_CFG STREAM off/on x DDR off/on (the Pmod's -IM part is DTR-capable; the bare
   W25Q128JVSSIQ is not: with that part only the DDR=0 passes mean anything).

   The checks run from code in PSRAM (section .ramcode, copied by crt0), not from flash: with DDR on and a
   wrong DDR_CAP an instruction fetch from flash returns garbage and the core is gone. DDR_CAP depends on the
   round trip and the clock (docs/qspi-ddr.md section 3), so a DDR pass first sweeps DDR_CAP 0..7 with a short
   probe, prints the passing set (INFO), and runs the full checks at the middle of the longest passing run. */
#include "hw.h"

#define SEED 0x2545F491u
static inline __attribute__((always_inline)) u32 xs(u32 x) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x; }

static const u32 crc_tab[16] = {   /* CRC-32 (0xEDB88320), 4 bits at a time */
    0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC, 0x76DC4190, 0x6B6B51F4, 0x4DB26158, 0x5005713C,
    0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C, 0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C };
static inline __attribute__((always_inline)) u32 crc_word(u32 c, u32 w) {   /* four bytes, little-endian, eight nibbles */
    int i;
    c ^= w;                                   /* CRC is linear: xor the word in, then 8 nibble steps */
    for (i = 0; i < 8; i++) c = (c >> 4) ^ crc_tab[c & 15];
    return c;
}

#define RAM __attribute__((section(".ramcode"), noinline))
#define PROBE_WORDS 128

/* Short read test, run from PSRAM with QSPI_CFG = qcfg; QSPI_CFG goes back to 'restore'. 0 = every word right. */
RAM u32 ram_probe(u32 qcfg, u32 restore) {
    volatile const u32 *pw = pattern;
    u32 x = SEED, bad = 0, i;
    R32(SC_QCFG) = qcfg;
    for (i = 0; i < PROBE_WORDS; i++) { x = xs(x); bad |= pw[i] ^ x; }
    R32(SC_QCFG) = restore;
    return bad;
}

/* The checks, run from PSRAM with QSPI_CFG = qcfg, then QSPI_CFG = restore. Returns a mask: bit n = check n failed. */
RAM u32 ram_check(u32 qcfg, u32 restore) {
    volatile const u32 *pw = pattern;
    volatile const u16 *ph = (volatile const u16 *)pattern;
    volatile const u8  *pb = (volatile const u8 *)pattern;
    u32 x, c, s, i, exp_c, fail = 0;
    R32(SC_QCFG) = qcfg;

    x = SEED; exp_c = 0xFFFFFFFFu;
    for (i = 0; i < PAT_WORDS; i++) { x = xs(x); exp_c = crc_word(exp_c, x); }

    /* 0: word loads, forward: CRC-32 */
    c = 0xFFFFFFFFu;
    for (i = 0; i < PAT_WORDS; i++) c = crc_word(c, pw[i]);
    fail |= (c != exp_c) << 0;

    /* 1: byte loads, forward, against the sequence; also lb sign */
    x = SEED; s = 0;
    for (i = 0; i < PAT_WORDS; i++) {
        u32 w, b;
        x = xs(x);
        w = ((u32)pb[4*i]) | ((u32)pb[4*i+1] << 8) | ((u32)pb[4*i+2] << 16) | ((u32)pb[4*i+3] << 24);
        s |= w ^ x;
        b = (u32)(u8)((volatile const s8 *)pattern)[4*i + 3];
        s |= (b ^ (x >> 24));
    }
    fail |= (s != 0) << 1;

    /* 2: halfword loads, forward, both signed and unsigned */
    x = SEED; s = 0;
    for (i = 0; i < PAT_WORDS; i++) {
        u32 lo, hi;
        x = xs(x);
        lo = ph[2*i]; hi = ph[2*i+1];
        s |= (lo | (hi << 16)) ^ x;
        s |= ((u32)(u16)((volatile const s16 *)pattern)[2*i + 1]) ^ (x >> 16);
    }
    fail |= (s != 0) << 2;

    /* 3-5: word loads backward and with strides 4 and 7: a streaming read must not mask a wrong address */
    x = SEED; s = 0;
    for (i = 0; i < PAT_WORDS; i++) { x = xs(x); s += x; }
    c = 0;
    for (i = PAT_WORDS; i > 0; i--) c += pw[i - 1];
    fail |= (c != s) << 3;
    c = 0;
    for (i = 0; i < 4; i++) { u32 j; for (j = i; j < PAT_WORDS; j += 4) c += pw[j]; }
    fail |= (c != s) << 4;
    c = 0;
    for (i = 0; i < 7; i++) { u32 j; for (j = i; j < PAT_WORDS; j += 7) c += pw[j]; }
    fail |= (c != s) << 5;

    /* 6: 1 KB boundary (interior at +0x400, and past the end of the checked region at +0x800): words either
       side in both orders, a halfword pair and a byte pair straddling it */
    {
        u32 k, bad = 0;
        for (k = 256; k <= 512; k += 256) {
            u32 a0, a1;
            x = SEED; for (i = 0; i < k - 1; i++) x = xs(x);
            a0 = xs(x); a1 = xs(a0);              /* words k-1 and k */
            bad |= pw[k - 1] ^ a0; bad |= pw[k] ^ a1;
            bad |= pw[k] ^ a1;     bad |= pw[k - 1] ^ a0;
            bad |= ph[2*k - 1] ^ (a0 >> 16); bad |= ph[2*k] ^ (a1 & 0xFFFF);
            bad |= pb[4*k - 1] ^ (a0 >> 24); bad |= pb[4*k] ^ (a1 & 0xFF);
        }
        fail |= (bad != 0) << 6;
    }
    R32(SC_QCFG) = restore;
    return fail;
}

static const char *const check_name[7] = {
    "crc, lw forward", "lbu/lb every byte", "lhu/lh every halfword", "sum, lw backward",
    "sum, lw stride 4", "sum, lw stride 7", "lw/lh/lb around the 1 KB boundaries" };

/* DDR_CAP sweep (SDR flash code; QSPI_CFG = base with cap<<2 only while the probe runs from PSRAM, then 'restore').
   Returns the chosen cap (middle of the longest passing run) or 8 when nothing passes; *mask = passing set. */
u32 ddr_pick_cap(u32 base, u32 restore, u32 *mask) {
    u32 cap, m = 0, run = 0, best = 0, best_end = 0;
    for (cap = 0; cap < 8; cap++) {
        if (ram_probe((base & ~0x1Cu) | (cap << 2), restore) == 0) m |= 1u << cap;
    }
    for (cap = 0; cap < 8; cap++) {
        if (m & (1u << cap)) { run++; if (run > best) { best = run; best_end = cap; } }
        else run = 0;
    }
    *mask = m;
    if (!best) return 8;
    return best_end - ((best - 1) >> 1);
}

static void one_cfg(u32 cfg) {
    u32 q = R32(SC_QCFG), qc, f, i, mask = 0, cap = (q >> 2) & 7;
    qc = (q & ~3u) | cfg;
    if (cfg & 2) {
        cap = ddr_pick_cap(qc, q, &mask);
        puts_("INFO flash ddr cfg="); putd(cfg); puts_(" cap_pass_mask="); putx(mask); puts_(" cap="); putd(cap); puts_("\n");
        chk(mask != 0, 1, "a DDR_CAP passes the probe");
        if (cap == 8) return;
        qc = (qc & ~0x1Cu) | (cap << 2);
    }
    f = ram_check(qc, q);
    chk(f == 0, 1, "all flash read checks");
    for (i = 0; i < 7; i++) if (f & (1u << i)) { puts_("FAIL flash "); puts_(check_name[i]); puts_(" cfg="); putd(cfg); puts_("\n"); }
}

void t_flash(void) {
    u32 q = R32(SC_QCFG);
    u32 cfg;
    t_begin("flash");
    for (cfg = 0; cfg < 4; cfg++) one_cfg(cfg);
    chk(R32(SC_QCFG), q, "QSPI_CFG restored");
    t_end();
}
