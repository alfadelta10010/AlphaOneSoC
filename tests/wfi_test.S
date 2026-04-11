# WFI test — verifies core halts on WFI and resumes on timer interrupt
#
# CLINT base: 0x0200_0000  →  lui tN, 0x2000
#   mtimecmp @ 0x0200_4000  →  lui tN, 0x2004
#   mtime    @ 0x0200_BFF8  →  lui tN, 0x200C; offset -8

.section .text.init
.globl _start

.option push
.option norvc

_start:
    # Install trap handler
    la    t0, trap_handler
    csrw  mtvec, t0
    addi  s4, zero, 0        # trap_count = 0
    lui   s2, 0x80000
    addi  s2, s2, 7          # s2 = 0x80000007

    # Reset mtime = 0
    lui   t0, 0x200C          # t0 = 0x0200_C000
    sw    zero, -8(t0)        # mtime_lo = 0
    sw    zero, -4(t0)        # mtime_hi = 0

    # Set mtimecmp = 20 (fires quickly after WFI)
    lui   t0, 0x2004          # t0 = 0x0200_4000
    addi  t1, zero, 20
    sw    t1, 0(t0)           # mtimecmp_lo = 20
    sw    zero, 4(t0)         # mtimecmp_hi = 0

    # Enable MTIE
    addi  t1, zero, 0x80
    csrw  mie, t1

    # Enable global interrupts
    addi  t1, zero, 8
    csrw  mstatus, t1

    # Execute WFI — core stalls until timer fires
    .word 0x10500073          # WFI

    # Execution resumes here after interrupt handler returns via MRET
    csrw  mstatus, zero       # disable further interrupts

    # Verify trap fired
    beq   s4, zero, fail_no_trap

    # Verify mcause == 0x80000007
    bne   s3, s2, fail_cause

    # SUCCESS
    addi  a0, zero, 0
    j     .

fail_no_trap:
    addi  a0, zero, 1
    j     .

fail_cause:
    addi  a0, zero, 2
    j     .

# ---- Trap handler ----
.align 4
trap_handler:
    csrr  s3, mcause
    addi  s4, s4, 1

    # Disarm timer
    lui   t0, 0x2004
    addi  t1, zero, -1
    sw    t1, 0(t0)
    sw    t1, 4(t0)

    mret

.option pop
