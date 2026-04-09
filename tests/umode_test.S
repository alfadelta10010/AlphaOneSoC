# U-mode privilege test
# Tests M+U mode switching, ECALL cause, and CSR access control from U-mode.
# a0 = 0 on success, test number on failure
#
# Convention:
#   s2 = expected mcause
#   s3 = actual mcause (set by trap handler)
#   s4 = trap-fired flag (set by trap handler)
#   s6 = override return address (if non-zero, trap handler returns here instead of mepc+4)

.section .text.init
.globl _start
.option push
.option norvc

_start:
    la    t0, trap_handler
    csrw  mtvec, t0
    addi  a0, zero, 0
    addi  s6, zero, 0      # clear override

    # ===== Test 1: ECALL from M-mode → cause 11 =====
    addi  s2, zero, 11
    addi  s4, zero, 0
    ecall
    addi  t0, zero, 1
    bne   s4, t0, fail_1
    bne   s3, s2, fail_1

    # ===== Set up PMP before entering U-mode =====
    # Entry 0: NAPOT covering full 4GB, RWX, unlocked.
    # pmpaddr[29:0] = all-ones (0x1FFFFFFF) → size 2^32 (full space).
    # pmpcfg byte 0: A=NAPOT(11), R=1, W=1, X=1, L=0 → 0x1F
    li    t0, 0x1FFFFFFF
    csrw  pmpaddr0, t0
    li    t0, 0x1F
    csrw  pmpcfg0, t0

    # ===== Switch to U-mode via MRET =====
    # Enable cycle counter for U-mode (mcounteren[0]=1); instret stays off (mcounteren[2]=0)
    addi  t0, zero, 1
    csrw  mcounteren, t0

    csrr  t0, mstatus
    lui   t1, 0x2
    addi  t1, t1, -0x800   # t1 = 0x1800 (MPP bits)
    not   t1, t1
    and   t0, t0, t1        # clear MPP → U-mode on next MRET
    csrw  mstatus, t0
    la    t0, umode_entry
    csrw  mepc, t0
    mret                    # → U-mode

umode_entry:
    # ===== Test 2: ECALL from U-mode → cause 8 =====
    addi  s2, zero, 8
    addi  s4, zero, 0
    ecall                   # trap → M-mode handler → mret back here+4 in U-mode
    addi  t0, zero, 1
    bne   s4, t0, fail_2
    bne   s3, s2, fail_2

    # ===== Test 3: M-mode CSR from U-mode → illegal instruction =====
    # Use s6 as "override return" so trap handler jumps to check_3
    la    s6, check_3
    addi  s2, zero, 2      # expected cause: illegal
    addi  s4, zero, 0
    csrr  t0, mscratch     # 0x340: M-only CSR, should trap from U-mode
    j     fail_3            # no trap → fail
check_3:
    addi  t0, zero, 1
    bne   s4, t0, fail_3
    bne   s3, s2, fail_3

    # ===== Test 4: U-mode cycle CSR (0xC00) does NOT trap when mcounteren[0]=1 =====
    addi  s4, zero, 0
    csrr  t0, cycle        # 0xC00: mcounteren[0]=1 → accessible from U-mode
    bne   s4, zero, fail_4

    # ===== Test 5: U-mode instret CSR (0xC02) traps when mcounteren[2]=0 =====
    la    s6, check_5
    addi  s2, zero, 2      # expected cause: illegal instruction
    addi  s4, zero, 0
    csrr  t0, instret      # 0xC02: mcounteren[2]=0 → should trap from U-mode
    j     fail_5
check_5:
    addi  t0, zero, 1
    bne   s4, t0, fail_5
    bne   s3, s2, fail_5

    # SUCCESS
    addi  a0, zero, 0
_halt: j _halt

# ---- Trap handler (always runs in M-mode) ----
# Records mcause in s3, sets s4=1.
# If s6 != 0: redirects mepc to s6 (for tests where fallthrough is "no trap" path).
# Otherwise: advances mepc by 4.
# mret restores privilege from MPP (back to caller's privilege level).
.align 4
trap_handler:
    csrr  s3, mcause
    addi  s4, zero, 1
    beq   s6, zero, use_mepc4   # no override → advance mepc normally
    csrw  mepc, s6              # override: return to specified label
    addi  s6, zero, 0           # clear override for next trap
    mret
use_mepc4:
    csrr  t5, mepc
    addi  t5, t5, 4
    csrw  mepc, t5
    mret

fail_1:  addi a0, zero, 1; j _halt
fail_2:  addi a0, zero, 2; j _halt
fail_3:  addi a0, zero, 3; j _halt
fail_4:  addi a0, zero, 4; j _halt
fail_5:  addi a0, zero, 5; j _halt

.option pop
