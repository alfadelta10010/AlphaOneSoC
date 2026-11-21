#!/usr/bin/env python3
"""Pattern flash region: N+4 xorshift32 words (seed 0x2545F491) as an assembler file.
The firmware regenerates the same sequence in registers and compares: it never trusts the image."""
import sys
n = int(sys.argv[1]) + 4
x = 0x2545F491
print('\t.section .pattern,"a"\n\t.globl pattern\npattern:')
for _ in range(n):
    x ^= (x << 13) & 0xFFFFFFFF
    x ^= x >> 17
    x ^= (x << 5) & 0xFFFFFFFF
    print('\t.word 0x%08x' % x)
