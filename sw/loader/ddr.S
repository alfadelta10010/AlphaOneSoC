/* Boot-time DDR capture sweep with an SDR fallback: boot contract rule 8 (docs/ROADMAP.md 9.1),
 * docs/qspi-ddr.md section 6. A port of tests/soc/ddr_sweep.S, which the SoC bench checks
 * against the Pmod model, to the loader. The boot always starts in SDR with streaming on
 * (QSPI_CFG resets on every reset). ddr_sweep() then
 *   1. copies the sweep code and a trap handler to PSRAM and runs there; from here no
 *      instruction is fetched from flash until the execute test,
 *   2. copies a 64-word block of flash into PSRAM with DDR off (the reference),
 *   3. for DDR_CAP 1..6 sets QSPI_CFG = {cap, DDR, STREAM}, reads the block 3 times with loads
 *      and compares: a point passes with no mismatch; back to SDR after each. The choice: no
 *      point passing means SDR; else the longest run of passing points (ties: the later run),
 *      point = start + length / 2,
 *   4. the execute test at the chosen point k: BOOT_MODE = 0xD8 + k, the watchdog armed (TOP 1:
 *      131072 to 196608 clocks), DDR on at k, a 300-instruction straight-line flash routine
 *      called and its checksum compared with the SDR one. A trap during it restores SDR and
 *      writes BOOT_MODE 0xDF; a hang ends in the watchdog's reboot, which the loader reads as
 *      "stay in SDR",
 *   5. back in flash, in DDR: the routine again, the block against the PSRAM copy, the routine
 *      once more; any difference restores SDR and writes BOOT_MODE 0xDF. The watchdog is then
 *      set to TOP 15 (2^31 to 1.5 * 2^31 clocks, 41 s at 52.63 MHz) and kicked: the payload
 *      services it from there (IMAGE_F_DDR).
 * Returns a0 = k + 1 when DDR is on (QSPI_CFG stays {k, DDR, STREAM}, BOOT_MODE stays 0xD8 + k),
 * 0 for SDR, with bit c of the byte above it set for each capture point c that passed the sweep;
 * a1 = the path: 0 DDR on, 1 no passing point, 2 trap in the execute test, 3 a
 * checksum or block mismatch.
 * The loader is built with -DDDR_FORCE_TRAP, -DDDR_FORCE_MISMATCH, -DDDR_FORCE_LATE_MISMATCH or -DDDR_FORCE_LATE_TRAP
 * (make LOADER_DEFS=...) to run the failure paths of the execute test and of the checks back in
 * flash, which no Pmod model behaviour reaches. mtvec is the PSRAM handler until label 9: a trap
 * in those checks restores SDR and BOOT_MODE 0xDF like one in the execute test.
 * Scratch in PSRAM: the code at PS_CODE, the reference at PS_REF, in the 64 KB the stack uses
 * the top of; the payload is already loaded below them. */
    .equ SYSCON,    0x10020000
    .equ PS_CODE,   0x80FF0000
    .equ PS_REF,    0x80FF1000
    .equ NWORDS,    64
    .equ NPASS,     3
#ifndef DDR_FINAL_TOP
#define DDR_FINAL_TOP 0xF         /* a test build (-DDDR_FINAL_TOP=6) shortens it: a payload that stops kicking then resets */
#endif
    .equ QCFG,      0x1C
    .equ BMODE,     0x08
    .equ WTORR,     0x104
    .equ WCR,       0x100
    .equ WCRR,      0x10C

    .section .text
    .globl ddr_sweep
ddr_sweep:
    addi    sp, sp, -64
    sw      ra, 0(sp)
    .irp n,0,1,2,3,4,5,6,7,8,9,10,11
    sw      s\n, 4 + 4*\n(sp)
    .endr
    li      s11, SYSCON
    lw      a3, QCFG(s11)
    andi    a3, a3, 1                # a3 = STREAM as the no-stream strap left it: the sweep keeps it
    jal     ra, xrun                 # the SDR checksum
    mv      s8, a0
    la      s7, blk
    la      s6, xrun
    la      s5, after
    csrr    s4, mtvec
    la      t0, ps_start             # copy the blob to PSRAM
    la      t1, ps_end
    li      t2, PS_CODE
1:  lw      t3, 0(t0)
    sw      t3, 0(t2)
    addi    t0, t0, 4
    addi    t2, t2, 4
    bltu    t0, t1, 1b
    li      t0, PS_CODE + 4          # the trap handler sits right after the entry jump
    csrw    mtvec, t0
    fence.i
    li      t0, PS_CODE
    jr      t0

# ---- the blob: position independent, runs in PSRAM, addresses of flash symbols in s5-s7 ----
    .balign 4
ps_start:
    .option push
    .option norvc
    j       ps_entry                 # offset 0, 4 bytes
    .option pop
ps_trap:                             # offset 4 = mtvec
    mv      t0, a3
    sw      t0, QCFG(s11)            # SDR
    li      t0, 0xDF
    sw      t0, BMODE(s11)
    li      s10, 0
    li      s9, 2
    j       ps_done
ps_entry:
    li      t0, PS_REF               # reference copy, DDR off
    mv      t1, s7
    li      t2, NWORDS
1:  lw      t3, 0(t1)
    sw      t3, 0(t0)
    addi    t1, t1, 4
    addi    t0, t0, 4
    addi    t2, t2, -1
    bnez    t2, 1b
    li      s0, 1                    # sweep DDR_CAP 1..6
    li      s1, 0                    # bit c: cap c passed
2:  slli    t0, s0, 2
    ori     t0, t0, 2                # DDR on at this trial point, STREAM as the strap left it
    or      t0, t0, a3
    sw      t0, QCFG(s11)
    li      s2, NPASS
    li      s3, 0
3:  li      t0, PS_REF
    mv      t1, s7
    li      t2, NWORDS
4:  lw      t3, 0(t1)
    lw      t4, 0(t0)
    xor     t3, t3, t4
    or      s3, s3, t3
    addi    t1, t1, 4
    addi    t0, t0, 4
    addi    t2, t2, -1
    bnez    t2, 4b
    addi    s2, s2, -1
    bnez    s2, 3b
    mv      t0, a3
    sw      t0, QCFG(s11)            # SDR again
    beqz    s3, 10f                  # taken only on a known zero: an X from a floating pin
    j       5f                       # (simulation) must not read as a pass
10: li      t0, 1
    sll     t0, t0, s0
    or      s1, s1, t0
5:  addi    s0, s0, 1
    li      t0, 7
    bne     s0, t0, 2b
    li      s0, 1                    # the longest run of passing points, ties -> later
    li      s2, 0                    # current length
    li      s3, 0                    # best length
    li      a1, 0                    # current start
    li      a2, 0                    # best start
6:  srl     t0, s1, s0
    andi    t0, t0, 1
    beqz    t0, 8f
    bnez    s2, 7f
    mv      a1, s0
7:  addi    s2, s2, 1
    bltu    s2, s3, 9f
    mv      s3, s2
    mv      a2, a1
    j       9f
8:  li      s2, 0
9:  addi    s0, s0, 1
    li      t0, 7
    bne     s0, t0, 6b
    li      s9, 1
    li      s10, 0
    beqz    s3, ps_nopoint           # no passing point: stay SDR
    srli    t0, s3, 1
    add     s0, a2, t0               # start + length / 2
    addi    s10, s0, 1
    addi    t0, s0, 0xD8
    sw      t0, BMODE(s11)           # BOOT_MODE = 0xD8 + k
    li      t0, 1
    sw      t0, WTORR(s11)           # TOP 1, kicked
    sw      t0, WCR(s11)             # armed, for good
    slli    t0, s0, 2
    ori     t0, t0, 2
    or      t0, t0, a3
    sw      t0, QCFG(s11)            # DDR on at k
#ifdef DDR_FORCE_TRAP
    ebreak                           # a test build: a trap in the execute test
#endif
    jalr    ra, 0(s6)                # xrun from flash, in DDR
#ifndef DDR_FORCE_MISMATCH           /* (a test build: the checksum is taken as wrong) */
    beq     a0, s8, exec_ok
#endif
    mv      t0, a3
    sw      t0, QCFG(s11)
    li      t0, 0xDF
    sw      t0, BMODE(s11)
    li      s10, 0
    li      s9, 3
    j       ps_done
exec_ok:
    li      s9, 0
    j       ps_done
ps_nopoint:
    li      t0, 0xDF
    sw      t0, BMODE(s11)           # BOOT_MODE = DDR failed
    mv      t0, a3
    sw      t0, QCFG(s11)
ps_done:
    jr      s5                       # mtvec stays the PSRAM trap handler until the checks in flash are done
    .balign 4
ps_end:

# ---- back in flash ----------------------------------------------------------------
after:
    bnez    s10, 6f
    li      t0, 1
    beq     s9, t0, 9f               # no passing point: the watchdog was never armed
    j       7f                       # a trap or a mismatch in the execute test: it is armed
6:  li      t0, 0x76
    sw      t0, WCRR(s11)            # kick
#ifdef DDR_FORCE_LATE_TRAP
    ebreak                           # a test build: a trap in flash code after the kick, mtvec is the PSRAM handler
#endif
#ifdef DDR_FORCE_LATE_MISMATCH
    j       8f                       # a test build: the check back in flash finds a difference
#endif
    jal     ra, xrun                 # more flash code, in DDR
    bne     a0, s8, 8f
    la      t0, blk                  # and the block, against the PSRAM copy
    li      t1, PS_REF
    li      t2, NWORDS
2:  lw      t3, 0(t0)
    lw      t4, 0(t1)
    bne     t3, t4, 8f
    addi    t0, t0, 4
    addi    t1, t1, 4
    addi    t2, t2, -1
    bnez    t2, 2b
    jal     ra, xrun
    bne     a0, s8, 8f
    j       7f
8:  mv      t0, a3                   # a difference: SDR again, with the strap's STREAM bit
    sw      t0, QCFG(s11)
    li      t0, 0xDF
    sw      t0, BMODE(s11)
    li      s10, 0
    li      s9, 3
7:  li      t0, DDR_FINAL_TOP        # armed for good since the execute test began: TOP 15 unless a test build says less
    sw      t0, WTORR(s11)
9:  csrw    mtvec, s4                # the loader's own handler again, now that nothing is checked from flash
    slli    t0, s1, 8                # a0 = (the pass mask << 8) | (DDR_CAP + 1 or 0), a1 = the path
    or      a0, s10, t0
    mv      a1, s9
    lw      ra, 0(sp)
    .irp n,0,1,2,3,4,5,6,7,8,9,10,11
    lw      s\n, 4 + 4*\n(sp)
    .endr
    addi    sp, sp, 64
    ret

# 300+ straight-line instructions from immediates, then a short loop
xrun:
    li      a0, 0x1b5f
    li      t0, 0x3c7
    .set iv, 0x123
    .rept 40
    addi    a0, a0, (iv & 0x3ff)
    .set iv, (iv * 5 + 0x111) & 0xfffff
    li      t1, iv
    xori    a0, a0, (iv & 0x7ff)
    add     a0, a0, t1
    slli    t2, a0, 5
    xor     a0, a0, t2
    srli    t2, a0, 3
    add     a0, a0, t2
    add     t0, t0, a0
    .endr
    xor     a0, a0, t0
    li      t1, 24
1:  slli    t2, a0, 3
    xor     a0, a0, t2
    srli    t2, a0, 5
    xor     a0, a0, t2
    addi    a0, a0, 7
    addi    t1, t1, -1
    bnez    t1, 1b
    ret

    .section .rodata
    .align 2
blk:
    .set bv, 1
    .rept 32
    .word bv
    .set bv, (bv << 1) & 0xffffffff
    .endr
    .word 0x00000000, 0xffffffff, 0x0f0f0f0f, 0xf0f0f0f0
    .word 0x0000ffff, 0xffff0000, 0x55555555, 0xaaaaaaaa
    .set rv, 0x2545f491
    .rept 24
    .word rv
    .set rv, (rv * 1103515245 + 12345) & 0xffffffff
    .endr
