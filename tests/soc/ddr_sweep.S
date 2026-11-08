# Boot-time DDR flash capture sweep with an SDR fallback (WO-52), run from flash in
# the SoC bench. The boot always starts in SDR with streaming on (QSPI_CFG resets on
# every reset). This routine then
#   1. reads RESET_CAUSE and BOOT_MODE. BOOT_MODE 0xDF ("DDR failed"), or 0xD8 + k
#      with RESET_CAUSE.WDT (a crash while DDR was on at point k), keeps SDR: no sweep.
#      The WDT bit is consumed (W1C) so a later unrelated reboot does not fall back.
#   2. copies the sweep code and a trap handler to PSRAM and runs there; from here
#      no instruction is fetched from flash until the execute test.
#   3. copies a 64-word test block of flash into PSRAM with DDR off (the reference),
#   4. DDR_CAP 1..6: QSPI_CFG = {cap, DDR, STREAM}; reads the block 3 times with loads
#      and compares; a point passes with zero mismatches. Back to SDR after each.
#      Choice: no pass -> SDR; else the longest run of passing points (ties -> the
#      later run), point = start + length / 2 (1 -> it, 2 -> the later, 3 -> the
#      middle, 4 -> the upper middle ...).
#   5. execute test at the chosen point k: BOOT_MODE = 0xD8 + k, watchdog armed
#      (TORR TOP 1), DDR on at k, a 300-instruction straight-line flash routine
#      (xrun) is called and its checksum compared with the SDR one. A trap during
#      it: the PSRAM handler writes SDR and BOOT_MODE 0xDF and resumes in SDR. A
#      hang ends in the watchdog reboot and step 1.
#   6. pass: QSPI_CFG stays {k, DDR, STREAM}, BOOT_MODE stays 0xD8 + k, mtvec back,
#      jump to flash; the program runs more flash code in DDR, kicks, and reports.
#
# UART: "DDR on, cap k" or "DDR off". VALUE stores for the bench: 0xA.. pass mask
# (bit c = cap c passed), 0xB.. chosen k+1 (0 = none), 0xC.. path: 0 DDR on,
# 1 no passing point, 2 trap in the execute test, 3 checksum mismatch, 4 watchdog
# fallback (step 1), 5 BOOT_MODE 0xDF kept.
#
# Build flags (non-vacuity runs): -DNO_EXEC skips the execute test, -DPICK_FIRST takes
# the first passing point, -DTRAP_NOREST makes the handler skip the SDR restore,
# -DFORCE_FAIL makes every sweep point fail, -DWDT_AFTER spins after "DDR on"
# without servicing the watchdog (next boot: "DDR off").
#include "periph.h"

#define PS_CODE 0x80001000
#define PS_REF  0x80002000
#define NWORDS  64
#define NPASS   3
#define QCFG    0x1C
#define WCR     0x100
#define WTORR   0x104
#define WCRR    0x10C

.macro PUTC imm                      # t6 = UART
    li   t4, \imm
91: lbu  t5, LSR(t6)
    andi t5, t5, LSR_THRE
    beqz t5, 91b
    sb   t4, THR(t6)
.endm
.macro VAL tag, r
    li   t4, \tag
    slli t4, t4, 24
    or   t4, t4, \r
    sw   t4, MB_VALUE(s11)
.endm

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    lw   s0, 4(s11)                  # RESET_CAUSE (the WDT bit is consumed below)
    lw   s1, 8(s11)                  # BOOT_MODE
    li   t0, 0xDF
    beq  s1, t0, kept_sdr
    addi t1, s1, -0xD8
    li   t2, 8
    bgeu t1, t2, probe               # not 0xD8..0xDF
    andi t0, s0, 4
    bnez t0, wdt_fallback
    j    probe
kept_sdr:
    li   s9, 5
    j    stay_sdr
wdt_fallback:
    li   s9, 4
stay_sdr:
    li   s10, 0
    li   t0, 4
    sw   t0, 4(s11)                  # W1C the WDT bit
    li   t0, 0xDF
    sw   t0, 8(s11)
    j    report

probe:
    li   t0, 4
    sw   t0, 4(s11)                  # a WDT bit left over from an earlier boot is stale now
    jal  ra, xrun                    # the SDR checksum
    mv   s8, a0
    la   s7, blk
    la   s6, xrun
    la   s5, after
    csrr s4, mtvec
    la   t0, ps_start                # copy the blob to PSRAM
    la   t1, ps_end
    li   t2, PS_CODE
1:  lw   t3, 0(t0)
    sw   t3, 0(t2)
    addi t0, t0, 4
    addi t2, t2, 4
    bltu t0, t1, 1b
    li   t0, PS_CODE + 4             # the trap handler sits right after the entry jump
    csrw mtvec, t0
    fence.i
    li   t0, PS_CODE
    jr   t0

# ---- the blob: position independent, runs in PSRAM -------------------------------
    .balign 4
ps_start:
    .option push
    .option norvc
    j    ps_entry                    # offset 0, 4 bytes
    .option pop
ps_trap:                             # offset 4 = mtvec
#ifndef TRAP_NOREST
    li   t0, 1
    sw   t0, QCFG(s11)               # SDR
#endif
    li   t0, 0xDF
    sw   t0, 8(s11)
    li   s10, 0
    li   s9, 2
    j    ps_done
ps_entry:
    li   t0, PS_REF                  # reference copy, DDR off
    mv   t1, s7
    li   t2, NWORDS
1:  lw   t3, 0(t1)
    sw   t3, 0(t0)
    addi t1, t1, 4
    addi t0, t0, 4
    addi t2, t2, -1
    bnez t2, 1b
    li   s0, 1                       # sweep DDR_CAP 1..6
    li   s1, 0
2:  slli t0, s0, 2
    ori  t0, t0, 3
    sw   t0, QCFG(s11)
    li   s2, NPASS
    li   s3, 0
3:  li   t0, PS_REF
    mv   t1, s7
    li   t2, NWORDS
4:  lw   t3, 0(t1)
    lw   t4, 0(t0)
    xor  t3, t3, t4
    or   s3, s3, t3
    addi t1, t1, 4
    addi t0, t0, 4
    addi t2, t2, -1
    bnez t2, 4b
    addi s2, s2, -1
    bnez s2, 3b
    li   t0, 1
    sw   t0, QCFG(s11)               # SDR again
#ifdef FORCE_FAIL
    li   s3, 1
#endif
    beqz s3, 10f                     # taken only on a known zero: an X from a floating pin
    j    5f                          # (simulation) must not read as a pass
10: li   t0, 1
    sll  t0, t0, s0
    or   s1, s1, t0
5:  addi s0, s0, 1
    li   t0, 7
    bne  s0, t0, 2b
    VAL  0xA0, s1
    li   s0, 1                       # the longest run of passing points, ties -> later
    li   s2, 0                       # current length
    li   s3, 0                       # best length
    li   a1, 0                       # current start
    li   a2, 0                       # best start
6:  srl  t0, s1, s0
    andi t0, t0, 1
    beqz t0, 8f
    bnez s2, 7f
    mv   a1, s0
7:  addi s2, s2, 1
    bltu s2, s3, 9f
    mv   s3, s2
    mv   a2, a1
    j    9f
8:  li   s2, 0
9:  addi s0, s0, 1
    li   t0, 7
    bne  s0, t0, 6b
    li   s9, 1
    li   s10, 0
    beqz s3, ps_vals                 # no passing point: stay SDR
#ifdef PICK_FIRST
    mv   s0, a2
#else
    srli t0, s3, 1
    add  s0, a2, t0                  # start + length / 2
#endif
    addi s10, s0, 1
    VAL  0xB0, s10
    addi t0, s0, 0xD8
    sw   t0, 8(s11)                  # BOOT_MODE = 0xD8 + k
    li   t0, 1
    sw   t0, WTORR(s11)              # TOP 1: 131072..196608 clocks, kicked
    sw   t0, WCR(s11)                # armed, for good
    slli t0, s0, 2
    ori  t0, t0, 3
    sw   t0, QCFG(s11)               # DDR on at k
#ifndef NO_EXEC
    jalr ra, 0(s6)                   # xrun from flash, in DDR
    beq  a0, s8, exec_ok
    li   t0, 1
    sw   t0, QCFG(s11)
    li   t0, 0xDF
    sw   t0, 8(s11)
    li   s10, 0
    li   s9, 3
    j    ps_done
#endif
exec_ok:
    li   s9, 0
    j    ps_done
ps_vals:
    li   t0, 0xDF
    sw   t0, 8(s11)                  # BOOT_MODE = DDR failed
    li   t0, 1
    sw   t0, QCFG(s11)
ps_done:
    csrw mtvec, s4
    jr   s5
    .balign 4
ps_end:

# ---- back in flash ----------------------------------------------------------------
after:
    VAL  0xC0, s9
    beqz s10, report
    li   t0, 0x76
    sw   t0, WCRR(s11)               # kick
    jal  ra, xrun                    # more flash code, in DDR
    CHECKR a0, s8, 0x701
    la   t0, blk                     # and the block, against the PSRAM copy
    li   t1, PS_REF
    li   t2, NWORDS
2:  lw   t3, 0(t0)
    lw   t4, 0(t1)
    CHECKR t3, t4, 0x702
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -1
    bnez t2, 2b
    jal  ra, xrun
    CHECKR a0, s8, 0x703

report:                              # s10 = k + 1 (DDR on) or 0
    li   t6, UART
    bnez s10, 3f
    VAL  0xC0, s9
    PUTC 'D'
    PUTC 'D'
    PUTC 'R'
    PUTC ' '
    PUTC 'o'
    PUTC 'f'
    PUTC 'f'
    j    4f
3:  PUTC 'D'
    PUTC 'D'
    PUTC 'R'
    PUTC ' '
    PUTC 'o'
    PUTC 'n'
    PUTC ','
    PUTC ' '
    PUTC 'c'
    PUTC 'a'
    PUTC 'p'
    PUTC ' '
    addi s10, s10, '0' - 1
91: lbu  t5, LSR(t6)
    andi t5, t5, LSR_THRE
    beqz t5, 91b
    sb   s10, THR(t6)
4:  PUTC '\n'
#ifdef WDT_AFTER
    bnez s10, 5f
#endif
    j    test_pass
#ifdef WDT_AFTER
5:  j    5b                          # DDR on, watchdog not serviced: it resets us
#endif

# 300+ straight-line instructions from immediates, then a short loop
xrun:
    li   a0, 0x1b5f
    li   t0, 0x3c7
    .set iv, 0x123
    .rept 40
    addi a0, a0, (iv & 0x3ff)
    .set iv, (iv * 5 + 0x111) & 0xfffff
    li   t1, iv
    xori a0, a0, (iv & 0x7ff)
    add  a0, a0, t1
    slli t2, a0, 5
    xor  a0, a0, t2
    srli t2, a0, 3
    add  a0, a0, t2
    add  t0, t0, a0
    .endr
    xor  a0, a0, t0
    li   t1, 24
1:  slli t2, a0, 3
    xor  a0, a0, t2
    srli t2, a0, 5
    xor  a0, a0, t2
    addi a0, a0, 7
    addi t1, t1, -1
    bnez t1, 1b
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

    .text
    EPILOGUE
