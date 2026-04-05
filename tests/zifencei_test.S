# Zifencei Test
# Tests FENCE.I instruction execution (does not crash, pipeline flushes correctly)
# a0 = 0 on success, test number on failure
#
# In a single-hart simulation, FENCE.I simply flushes the pipeline.
# We verify it doesn't break normal execution flow.

.section .text.init
.globl _start
_start:
    addi  a0, zero, 0

    # ===== Test 1: FENCE.I doesn't crash =====
    addi  t0, zero, 1
    fence.i
    addi  t1, zero, 1
    bne   t0, t1, fail_1

    # ===== Test 2: FENCE.I preserves register state =====
    addi  t0, zero, 42
    addi  t1, zero, 99
    addi  t2, zero, -1
    fence.i
    addi  t3, zero, 42
    bne   t0, t3, fail_2
    addi  t3, zero, 99
    bne   t1, t3, fail_2
    addi  t3, zero, -1
    bne   t2, t3, fail_2

    # ===== Test 3: FENCE.I between stores and instruction fetch =====
    # Store a value, fence.i, then verify the store took effect
    lui   t0, 0x1          # t0 = 0x1000
    addi  t1, zero, 0x55
    sw    t1, 0(t0)
    fence.i                # ensure icache coherence (no-op in sim but must not break)
    lw    t2, 0(t0)
    addi  t3, zero, 0x55
    bne   t2, t3, fail_3

    # ===== Test 4: Multiple FENCE.I in sequence =====
    fence.i
    fence.i
    fence.i
    addi  t0, zero, 4
    addi  t1, zero, 4
    bne   t0, t1, fail_4

    # ===== Test 5: FENCE (data fence) also doesn't crash =====
    addi  t0, zero, 10
    fence
    addi  t1, zero, 10
    bne   t0, t1, fail_5

    # ===== Test 6: FENCE.I after branch =====
    addi  t0, zero, 1
    bne   t0, zero, test_6_taken
    j     fail_6
test_6_taken:
    fence.i
    addi  t1, zero, 6
    addi  t2, zero, 6
    bne   t1, t2, fail_6

    # ===== Test 7: FENCE.I before branch =====
    addi  t0, zero, 7
    fence.i
    addi  t1, zero, 7
    beq   t0, t1, test_7_pass
    j     fail_7
test_7_pass:

    # SUCCESS
    addi  a0, zero, 0
    ecall

fail_1: addi a0, zero, 1; ecall
fail_2: addi a0, zero, 2; ecall
fail_3: addi a0, zero, 3; ecall
fail_4: addi a0, zero, 4; ecall
fail_5: addi a0, zero, 5; ecall
fail_6: addi a0, zero, 6; ecall
fail_7: addi a0, zero, 7; ecall
