# PMP test — Physical Memory Protection
# Tests NAPOT + TOR address matching, lock enforcement, and U-mode access control.
# a0=0 on success, test number on failure.
#
# Convention:
#   s2 = expected mcause
#   s3 = actual mcause (set by trap handler)
#   s4 = trap-fired flag (set by trap handler)
#   s5 = mtval from trap handler
#   s6 = override return address (non-zero → handler goes here instead of mepc+4)
#
# PMP layout (configured in _start):
#   Entry 0: NAPOT 4KB at 0x0000  RWX, unlocked  — covers code/data
#   Entry 1: TOR  [0x7FC,0x2000)  RW,  unlocked  — covers data extension
#   Entry 2: NAPOT 4KB at 0x2000  RWX, LOCKED    — tests lock enforcement
#   Entry 3: OFF
#
# 0x3000+ has no PMP entry → U-mode denied by default (used for fault tests).

.section .text.init
.globl _start
.option push
.option norvc

_start:
    la    t0, trap_handler
    csrw  mtvec, t0
    addi  a0, zero, 0
    addi  s6, zero, 0

    # ── Configure PMP ─────────────────────────────────────────────────────────
    # Entry 0: NAPOT 4KB at 0x0000.  4KB = 2^12, t=9 → pmpaddr[8:0]=1s → 0x1FF
    li    t0, 0x000001FF
    csrw  pmpaddr0, t0
    # Entry 1: TOR upper bound 0x2000 → pmpaddr1 = 0x2000>>2 = 0x800
    li    t0, 0x00000800
    csrw  pmpaddr1, t0
    # Entry 2: NAPOT 4KB at 0x2000.  base>>2=0x800, pmpaddr = 0x800|0x1FF = 0x9FF
    li    t0, 0x000009FF
    csrw  pmpaddr2, t0
    # pmpcfg0:  byte0=0x1F(entry0,NAPOT,RWX,L=0)  byte1=0x0B(entry1,TOR,RW,L=0)
    #           byte2=0x9F(entry2,NAPOT,RWX,L=1)   byte3=0x00(entry3,OFF)
    li    t0, 0x009F0B1F
    csrw  pmpcfg0, t0

    # ── Test 1: locked pmpaddr2 cannot be modified ─────────────────────────────
    li    t0, 0xDEADBEEF
    csrw  pmpaddr2, t0      # should be ignored — entry 2 locked
    csrr  t0, pmpaddr2
    li    t1, 0x000009FF    # expect original value
    bne   t0, t1, fail_1

    # ── Test 1b: locked pmpcfg0 byte 2 cannot be cleared ──────────────────────
    li    t0, 0x001F0B1F    # byte 2 = 0x1F (try to clear L bit)
    csrw  pmpcfg0, t0
    csrr  t0, pmpcfg0
    srli  t0, t0, 16
    andi  t0, t0, 0xFF      # extract byte 2
    li    t1, 0x9F
    bne   t0, t1, fail_1    # byte 2 must remain 0x9F
    # pmpcfg0 after: 0x009F0B1F (unlocked bytes updated to same value, locked unchanged) ✓

    # ── Test 2 (M-mode): load from 0x3000 — no PMP match → M-mode allowed ─────
    addi  s4, zero, 0
    li    t0, 0x3000
    lw    t1, 0(t0)         # M-mode: no entry matches → allowed
    bne   s4, zero, fail_2  # s4 must remain 0 (no trap)

    # ── Switch to U-mode (one time) for remaining tests ───────────────────────
    csrr  t0, mstatus
    lui   t1, 0x2
    addi  t1, t1, -0x800    # t1 = 0x1800 (MPP bits)
    not   t1, t1
    and   t0, t0, t1         # clear MPP → U-mode on MRET
    csrw  mstatus, t0
    la    t0, umode_entry
    csrw  mepc, t0
    mret

    # =========================================================================
    # U-mode section — we stay in U-mode until _halt
    # =========================================================================
umode_entry:
    # ── Test 3 (U-mode): load inside entry 0 (NAPOT 4KB, R=1) → no trap ──────
    addi  s4, zero, 0
    lw    t0, 0(zero)       # addr 0x0: entry 0, R allowed
    bne   s4, zero, fail_3  # s4 must remain 0

    # ── Test 4 (U-mode): load from 0x3000 — no match → cause 5 (load fault) ──
    addi  s4, zero, 0
    addi  s2, zero, 5       # expected cause
    la    s6, check_4
    li    t0, 0x3000
    lw    t1, 0(t0)         # U-mode: no PMP match → denied → cause 5
    j     fail_4
check_4:
    addi  t0, zero, 1
    bne   s4, t0, fail_4    # trap must have fired
    bne   s3, s2, fail_4    # cause must be 5

    # ── Test 5 (U-mode): store to 0x3000 — no match → cause 7 (store fault) ──
    addi  s4, zero, 0
    addi  s2, zero, 7
    la    s6, check_5
    li    t0, 0x3000
    sw    t1, 0(t0)         # U-mode: no PMP match → denied → cause 7
    j     fail_5
check_5:
    addi  t0, zero, 1
    bne   s4, t0, fail_5
    bne   s3, s2, fail_5

    # SUCCESS
    addi  a0, zero, 0
_halt: j _halt

# ── Trap handler (always runs in M-mode) ─────────────────────────────────────
.align 4
trap_handler:
    csrr  s3, mcause
    csrr  s5, mtval
    addi  s4, zero, 1
    beq   s6, zero, use_mepc4
    csrw  mepc, s6
    addi  s6, zero, 0
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
