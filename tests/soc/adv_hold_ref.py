#!/usr/bin/env python3
"""Reference signature for tests/soc/adv_hold.S, written from the RISC-V M/A/Zicsr semantics (not from the RTL).
usage: adv_hold_ref.py [SEED] [NK]   -> prints the expected SIG (8 hex digits)."""
import sys

M = 0xFFFFFFFF


def s32(x):
    x &= M
    return x - (1 << 32) if x & 0x80000000 else x


def lfsr(s):
    return ((s >> 1) ^ (0x80200003 if s & 1 else 0)) & M


def sigf(sig, r):
    return (((sig << 5) | (sig >> 27)) & M) ^ (r & M)


def div(a, b):
    sa, sb = s32(a), s32(b)
    if sb == 0:
        return M
    if sa == -(1 << 31) and sb == -1:
        return a
    q = abs(sa) // abs(sb)
    return (-q if (sa < 0) != (sb < 0) else q) & M


def rem(a, b):
    sa, sb = s32(a), s32(b)
    if sb == 0:
        return a
    if sa == -(1 << 31) and sb == -1:
        return 0
    r = abs(sa) % abs(sb)
    return (-r if sa < 0 else r) & M


def kernel(st, n):
    s4, a3, buf0, buf1 = st
    a0 = n
    while True:
        s4 = lfsr(s4); a2 = s4
        s4 = lfsr(s4); a4 = s4
        c = s4 & 0x70
        if c == 0:
            a4 = 0
        if c == 0x10:
            a2, a4 = 0x80000000, M
        sa, sb = s32(a2), s32(a4)
        a3 = (a3 + a2 * a4) & M                               # mul
        a3 = (a3 + ((sa * sb) >> 32)) & M                     # mulh, c.add
        a3 = (a3 << 1) & M                                    # c.slli 1
        a3 = (a3 + ((sa * a4) >> 32)) & M                     # mulhsu, c.add
        a3 ^= a2
        a3 ^= (a2 * a4) >> 32                                 # mulhu
        a3 = (a3 + div(a2, a4)) & M
        a3 = (a3 + (M if a4 == 0 else a2 // a4)) & M          # divu
        t0 = rem(a2, a4)
        a3 = (a3 << 3) & M                                    # c.slli 3
        a3 ^= t0
        a3 = (a3 + (a2 if a4 == 0 else a2 % a4)) & M          # remu
        sh = a4 & 31
        a3 = (a3 + ((a2 << sh) & M)) & M                      # sll
        a3 ^= a2 >> sh                                        # srl
        a3 = (a3 + ((sa >> sh) & M)) & M                      # sra
        buf0 = a3                                             # sw
        buf1 = (buf1 + a2) & M                                # lw, add, sw
        t0 = buf0; buf0 = (buf0 + a4) & M                     # amoadd.w
        a3 = (a3 + t0) & M
        buf0 = (buf0 + a2) & M                                # lr/sc retry loop
        a3 ^= buf0                                            # lw, xor
        a3 = (a3 + a3) & M                                    # mscratch round trip, c.add
        if (a0 & 7) == 3:                                     # wfi; c.addi a3, 1
            a3 = (a3 + 1) & M
        a0 -= 1
        if a0 == 0:
            break
    return (s4, a3, buf0, buf1)


def main():
    seed = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0x2468ACE1
    nk = int(sys.argv[2], 0) if len(sys.argv) > 2 else 24
    st = (seed, 0, 0, 0)
    sig = 0
    for _ in range(3):                                        # flash, PSRAM word, PSRAM halfword
        st = kernel(st, nk)
        sig = sigf(sig, st[1])
    sig = sigf(sig, st[3])
    print("%08x" % sig)


if __name__ == "__main__":
    main()
