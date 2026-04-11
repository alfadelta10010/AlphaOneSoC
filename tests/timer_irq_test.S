# Timer interrupt test — verifies mcause=0x80000007 on MTIP
#
# CLINT base: 0x0200_0000  →  lui tN, 0x2000  (= 0x2000 << 12 = 0x0200_0000)
#   msip       @ 0x0200_0000
#   mtimecmp   @ 0x0200_4000 (lo) [lui 0x2004], 0x0200_4004 (hi) [same base +4]
#   mtime      @ 0x0200_BFF8 (lo) [lui 0x200C; sw -8(base)], 0x0200_BFFC (hi)
#
# Strategy:
#   1. Install trap handler.
#   2. Reset mtime=0, set mtimecmp=50 via CLINT.
#   3. Enable MTIE (mie[7]) and MIE (mstatus[3]).
#   4. Spin until timer interrupt fires.
#   5. Verify mcause = 0x80000007.

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
    addi  s2, s2, 7          # s2 = 0x80000007 (timer interrupt cause)

    # Reset mtime = 0
    # mtime_lo @ 0x0200_BFF8 = 0x200C<<12 - 8
    lui   t0, 0x200C          # t0 = 0x0200_C000
    sw    zero, -8(t0)        # mtime_lo = 0  (0x0200_BFF8)
    sw    zero, -4(t0)        # mtime_hi = 0  (0x0200_BFFC)

    # Set mtimecmp = 50
    # mtimecmp_lo @ 0x0200_4000 = 0x2004<<12
    lui   t0, 0x2004          # t0 = 0x0200_4000
    addi  t1, zero, 50
    sw    t1, 0(t0)           # mtimecmp_lo = 50
    sw    zero, 4(t0)         # mtimecmp_hi = 0

    # Enable machine timer interrupt: mie[7] = MTIE
    addi  t1, zero, 0x80     # MTIE bit
    csrw  mie, t1

    # Enable global interrupts
    addi  t1, zero, 8
    csrw  mstatus, t1

    # Spin until timer fires
    addi  t2, zero, 0
spin:
    addi  t2, t2, 1
    lui   t3, 0x1             # 4096 iterations
    blt   t2, t3, spin_check
    j     fail_timeout
spin_check:
    bne   s4, zero, check_cause
    j     spin

check_cause:
    csrw  mstatus, zero
    bne   s3, s2, fail_cause

    # SUCCESS
    addi  a0, zero, 0
    j     .

fail_timeout:
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

    # Disarm: set mtimecmp = max to prevent repeated timer IRQ
    lui   t0, 0x2004
    addi  t1, zero, -1
    sw    t1, 0(t0)           # mtimecmp_lo = 0xFFFFFFFF
    sw    t1, 4(t0)           # mtimecmp_hi = 0xFFFFFFFF

    mret

.option pop
