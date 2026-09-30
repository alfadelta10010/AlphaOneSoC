# Boot from flash (SoC only: the MANIFEST mode `flash` builds this into the
# flash model, where the SoC boots, so the first fetch is 0x2000_0000).
# Everything up to the tohost store runs out of flash.
#
#  - a mix of 16- and 32-bit instructions, so some 32-bit instructions
#    straddle a word boundary in flash;
#  - word, halfword and byte loads of constants held in flash;
#  - stores to and loads from both PSRAM chips (A at 0x8000_0000, B at
#    0x8080_0000);
#  - the copy-and-jump a boot loader does: copy a routine from flash into
#    PSRAM, FENCE.I, call it there, and come back to flash.
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
    la   s0, consts
    lw   a0, 0(s0)             # 0x13579bdf
    lh   a1, 4(s0)             # 0xffff8421 (sign-extended)
    lhu  a2, 4(s0)             # 0x00008421
    lbu  a3, 7(s0)             # 0x5a
    lb   a4, 6(s0)             # 0xffffffa5
    add  a0, a0, a3
    addi a1, a1, 3
    li   s1, 0x80000100        # PSRAM A
    li   s2, 0x80800100        # PSRAM B
    sw   a0, 0(s1)
    sh   a1, 4(s1)
    sb   a4, 7(s1)
    sw   a2, 0(s2)
    lw   t0, 0(s1)
    lw   t1, 4(s1)
    lw   t2, 0(s2)
    xor  t3, t0, t2
    # Copy `routine` into PSRAM and run it there.
    la   t0, routine
    la   t1, routine_end
    li   t2, 0x80002000
    mv   s3, t2
1:  lw   t4, 0(t0)
    sw   t4, 0(t2)
    addi t0, t0, 4
    addi t2, t2, 4
    bltu t0, t1, 1b
    fence.i
    jalr ra, 0(s3)
    add  a7, a6, t3            # back in flash
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
2:  j 2b

# Position-independent, so it runs wherever it is copied to.
.align 2
routine:
    li   a5, 0x80800200
    sw   a0, 0(a5)
    lw   a6, 0(a5)
    addi a6, a6, 7
    ret
.align 2
routine_end:

.section .rodata
.align 2
consts:
    .word 0x13579bdf
    .half 0x8421
    .byte 0xa5, 0x5a

.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
