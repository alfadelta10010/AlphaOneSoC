/* T2: the flash read path. A pattern region linked into the image (gen_pattern.py) is read back with
   word, halfword and byte loads, and a CRC-32 over it is compared to the CRC of the same xorshift32
   sequence regenerated in registers, so the image itself is never the reference. The whole run is
   repeated for QSPI_CFG STREAM off/on x DDR off/on (the Pmod's -IM part is DTR-capable; the bare
   W25Q128JVSSIQ is not: with that part only the DDR=0 passes mean anything). */
#include "hw.h"

#define SEED 0x2545F491u
static inline u32 xs(u32 x) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x; }

static const u32 crc_tab[16] = {   /* CRC-32 (0xEDB88320), 4 bits at a time */
    0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC, 0x76DC4190, 0x6B6B51F4, 0x4DB26158, 0x5005713C,
    0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C, 0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C };
static inline u32 crc_word(u32 c, u32 w) {   /* four bytes, little-endian, eight nibbles */
    int i;
    c ^= w;                                   /* CRC is linear: xor the word in, then 8 nibble steps */
    for (i = 0; i < 8; i++) c = (c >> 4) ^ crc_tab[c & 15];
    return c;
}

static u32 expect_crc(void) {
    u32 x = SEED, c = 0xFFFFFFFFu;
    int i;
    for (i = 0; i < PAT_WORDS; i++) { x = xs(x); c = crc_word(c, x); }
    return ~c;
}
static void one_cfg(u32 cfg) {
    volatile const u32 *pw = pattern;
    volatile const u16 *ph = (volatile const u16 *)pattern;
    volatile const u8  *pb = (volatile const u8 *)pattern;
    u32 x, c, s, i, exp_c;
    u32 q = R32(SC_QCFG);
    R32(SC_QCFG) = (q & ~3u) | cfg;
    chk(R32(SC_QCFG) & 3, cfg, "QSPI_CFG readback");
    exp_c = expect_crc();

    /* word loads, forward: CRC-32 */
    c = 0xFFFFFFFFu;
    for (i = 0; i < PAT_WORDS; i++) c = crc_word(c, pw[i]);
    chk(~c, exp_c, "crc, lw forward");

    /* byte loads, forward, against the sequence; also lb sign */
    x = SEED; s = 0;
    for (i = 0; i < PAT_WORDS; i++) {
        u32 w, b;
        x = xs(x);
        w = ((u32)pb[4*i]) | ((u32)pb[4*i+1] << 8) | ((u32)pb[4*i+2] << 16) | ((u32)pb[4*i+3] << 24);
        s |= w ^ x;
        b = (u32)(u8)((volatile const s8 *)pattern)[4*i + 3];
        s |= (b ^ (x >> 24));
    }
    chk(s, 0, "lbu/lb every byte");

    /* halfword loads, forward, both signed and unsigned */
    x = SEED; s = 0;
    for (i = 0; i < PAT_WORDS; i++) {
        u32 lo, hi;
        x = xs(x);
        lo = ph[2*i]; hi = ph[2*i+1];
        s |= (lo | (hi << 16)) ^ x;
        s |= ((u32)(u16)((volatile const s16 *)pattern)[2*i + 1]) ^ (x >> 16);
    }
    chk(s, 0, "lhu/lh every halfword");

    /* word loads, backward and with a stride: a streaming read must not mask a wrong address */
    x = SEED; c = 0xFFFFFFFFu; s = 0;
    for (i = 0; i < PAT_WORDS; i++) { x = xs(x); s += x; }
    c = 0;
    for (i = PAT_WORDS; i > 0; i--) c += pw[i - 1];
    chk(c, s, "sum, lw backward");
    c = 0;
    for (i = 0; i < 4; i++) { u32 j; for (j = i; j < PAT_WORDS; j += 4) c += pw[j]; }
    chk(c, s, "sum, lw stride 4");
    c = 0;
    for (i = 0; i < 7; i++) { u32 j; for (j = i; j < PAT_WORDS; j += 7) c += pw[j]; }
    chk(c, s, "sum, lw stride 7");

    /* 1 KB boundary (interior at +0x400, and past the end of the checked region at +0x800): words either
       side in both orders, a halfword pair and a byte pair straddling it */
    {
        static const u32 bnd[2] = {256, 512};   /* word index of the boundary */
        u32 k;
        for (k = 0; k < 2; k++) {
            u32 b = bnd[k], a0, a1;
            x = SEED; for (i = 0; i < b - 1; i++) x = xs(x);
            a0 = xs(x); a1 = xs(a0);              /* words b-1 and b */
            chk(pw[b - 1], a0, "lw below 1KB boundary");
            chk(pw[b],     a1, "lw above 1KB boundary");
            chk(pw[b],     a1, "lw above 1KB boundary first");
            chk(pw[b - 1], a0, "lw below 1KB boundary second");
            chk(ph[2*b - 1], a0 >> 16, "lhu below 1KB boundary");
            chk(ph[2*b],     a1 & 0xFFFF, "lhu above 1KB boundary");
            chk(pb[4*b - 1], a0 >> 24, "lbu below 1KB boundary");
            chk(pb[4*b],     a1 & 0xFF, "lbu above 1KB boundary");
        }
    }
    R32(SC_QCFG) = q;
}

void t_flash(void) {
    u32 q = R32(SC_QCFG);
    u32 cfg;
    t_begin("flash");
    for (cfg = 0; cfg < 4; cfg++) one_cfg(cfg);
    R32(SC_QCFG) = q;
    chk(R32(SC_QCFG), q, "QSPI_CFG restored");
    t_end();
}
