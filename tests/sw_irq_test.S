# Software interrupt test — verifies mcause=0x80000003 on MSIP
#
# Strategy:
#   1. Install trap handler.
#   2. Enable MSIE (mie[3]) and MIE (mstatus[3]).
#   3. Write msip[0]=1 via CLINT MMIO — this raises sw_irq immediately.
#   4. The interrupt should fire on the next instruction boundary.
#   5. Verify trap_count != 0 and mcause = 0x80000003.
#
# CLINT base: 0x0200_0000  →  lui tN, 0x2000  (= 0x2000 << 12 = 0x0200_0000)
#   msip @ 0x0200_0000 (bit 0 = software interrupt pending)

.section .text.init
.globl _start

.option push
.option norvc

_start:
    # Install trap handler
    la    t0, trap_handler
    csrw  mtvec, t0
    addi  s4, zero, 0       # trap_count = 0
    lui   s2, 0x80000
    addi  s2, s2, 3          # s2 = 0x80000003 (software interrupt cause)

    # Enable machine software interrupt: mie[3] = MSIE
    addi  t1, zero, 0x8     # MSIE bit
    csrw  mie, t1

    # Enable global interrupts: mstatus.MIE = 1
    addi  t1, zero, 8
    csrw  mstatus, t1

    # Assert software interrupt via CLINT msip[0] = 1
    # CLINT base = 0x0200_0000 = 0x2000 << 12
    lui   t0, 0x2000          # t0 = 0x0200_0000
    addi  t1, zero, 1
    sw    t1, 0(t0)           # msip = 1 → triggers sw_irq

    # Spin briefly; interrupt should fire within a few cycles
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
    csrw  mstatus, zero       # disable interrupts
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
# Saves mcause into s3, increments s4, clears msip, returns.
.align 4
trap_handler:
    csrr  s3, mcause
    addi  s4, s4, 1

    # Clear software interrupt: msip = 0
    lui   t0, 0x2000          # t0 = 0x0200_0000
    sw    zero, 0(t0)         # msip = 0

    mret

.option pop
