# RV32A Atomic Extension Test
# a0 = 0 on success, test number on failure

.section .text.init
.globl _start
_start:
    # Setup: use address 0x1000 as atomic memory location
    lui   s2, 0x1          # s2 = 0x1000 (base address for atomics)
    addi  a0, zero, 0

    # ===== Test 1: LR.W / SC.W basic success =====
    addi  t0, zero, 42
    sw    t0, 0(s2)        # M[0x1000] = 42
    lr.w  t1, (s2)         # t1 = 42, set reservation
    addi  t2, zero, 99
    sc.w  t3, t2, (s2)     # store 99 → should succeed (t3=0)
    bne   t3, zero, fail_1
    lw    t4, 0(s2)
    addi  t5, zero, 99
    bne   t4, t5, fail_1

    # ===== Test 2: SC.W fails without LR.W =====
    addi  t0, zero, 55
    sc.w  t1, t0, (s2)     # no reservation → fail (t1=1)
    addi  t2, zero, 1
    bne   t1, t2, fail_2

    # ===== Test 3: LR.W reads correct value =====
    addi  t0, zero, 0x7F
    sw    t0, 0(s2)        # M[0x1000] = 0x7F
    lr.w  t1, (s2)
    addi  t2, zero, 0x7F
    bne   t1, t2, fail_3

    # ===== Test 4: SC.W fails after intervening store =====
    addi  t0, zero, 10
    sw    t0, 0(s2)
    lr.w  t1, (s2)         # reservation set
    addi  t2, zero, 20
    sw    t2, 0(s2)        # intervening store → invalidates reservation
    addi  t3, zero, 30
    sc.w  t4, t3, (s2)     # should fail (t4=1)
    addi  t5, zero, 1
    bne   t4, t5, fail_4

    # ===== Test 5: AMOSWAP.W =====
    addi  t0, zero, 100
    sw    t0, 0(s2)        # M[0x1000] = 100
    addi  t1, zero, 200
    amoswap.w t2, t1, (s2) # t2 = old(100), M[0x1000] = 200
    addi  t3, zero, 100
    bne   t2, t3, fail_5
    lw    t4, 0(s2)
    addi  t5, zero, 200
    bne   t4, t5, fail_5

    # ===== Test 6: AMOADD.W =====
    addi  t0, zero, 50
    sw    t0, 0(s2)        # M[0x1000] = 50
    addi  t1, zero, 25
    amoadd.w t2, t1, (s2)  # t2 = old(50), M[0x1000] = 75
    addi  t3, zero, 50
    bne   t2, t3, fail_6
    lw    t4, 0(s2)
    addi  t5, zero, 75
    bne   t4, t5, fail_6

    # ===== Test 7: AMOXOR.W =====
    addi  t0, zero, 0xFF
    sw    t0, 0(s2)        # M[0x1000] = 0xFF
    addi  t1, zero, 0x0F
    amoxor.w t2, t1, (s2)  # t2 = old(0xFF), M[0x1000] = 0xFF ^ 0x0F = 0xF0
    addi  t3, zero, 0xFF
    bne   t2, t3, fail_7
    lw    t4, 0(s2)
    addi  t5, zero, 0xF0
    bne   t4, t5, fail_7

    # ===== Test 8: AMOAND.W =====
    addi  t0, zero, 0xFF
    sw    t0, 0(s2)
    addi  t1, zero, 0x0F
    amoand.w t2, t1, (s2)  # t2 = old(0xFF), M = 0xFF & 0x0F = 0x0F
    addi  t3, zero, 0xFF
    bne   t2, t3, fail_8
    lw    t4, 0(s2)
    addi  t5, zero, 0x0F
    bne   t4, t5, fail_8

    # ===== Test 9: AMOOR.W =====
    addi  t0, zero, 0xF0
    sw    t0, 0(s2)
    addi  t1, zero, 0x0F
    amoor.w t2, t1, (s2)   # t2 = old(0xF0), M = 0xF0 | 0x0F = 0xFF
    addi  t3, zero, 0xF0
    bne   t2, t3, fail_9
    lw    t4, 0(s2)
    addi  t5, zero, 0xFF
    bne   t4, t5, fail_9

    # ===== Test 10: AMOMIN.W (signed) =====
    addi  t0, zero, 10
    sw    t0, 0(s2)        # M = 10
    addi  t1, zero, -5
    amomin.w t2, t1, (s2)  # t2 = old(10), M = min(10, -5) = -5
    addi  t3, zero, 10
    bne   t2, t3, fail_10
    lw    t4, 0(s2)
    addi  t5, zero, -5
    bne   t4, t5, fail_10

    # ===== Test 11: AMOMAX.W (signed) =====
    addi  t0, zero, -5
    sw    t0, 0(s2)        # M = -5
    addi  t1, zero, 10
    amomax.w t2, t1, (s2)  # t2 = old(-5), M = max(-5, 10) = 10
    addi  t3, zero, -5
    bne   t2, t3, fail_11
    lw    t4, 0(s2)
    addi  t5, zero, 10
    bne   t4, t5, fail_11

    # ===== Test 12: AMOMINU.W (unsigned) =====
    addi  t0, zero, 5
    sw    t0, 0(s2)        # M = 5
    addi  t1, zero, -1     # 0xFFFFFFFF unsigned
    amominu.w t2, t1, (s2) # t2 = old(5), M = minu(5, 0xFFFFFFFF) = 5
    addi  t3, zero, 5
    bne   t2, t3, fail_12
    lw    t4, 0(s2)
    addi  t5, zero, 5
    bne   t4, t5, fail_12

    # ===== Test 13: AMOMAXU.W (unsigned) =====
    addi  t0, zero, 5
    sw    t0, 0(s2)        # M = 5
    addi  t1, zero, -1     # 0xFFFFFFFF unsigned
    amomaxu.w t2, t1, (s2) # t2 = old(5), M = maxu(5, 0xFFFFFFFF) = 0xFFFFFFFF
    addi  t3, zero, 5
    bne   t2, t3, fail_13
    lw    t4, 0(s2)
    addi  t5, zero, -1
    bne   t4, t5, fail_13

    # ===== Test 14: AMOSWAP.W with zero =====
    addi  t0, zero, 77
    sw    t0, 0(s2)
    amoswap.w t2, zero, (s2) # t2 = old(77), M = 0
    addi  t3, zero, 77
    bne   t2, t3, fail_14
    lw    t4, 0(s2)
    bne   t4, zero, fail_14

    # ===== Test 15: AMOADD.W overflow =====
    lui   t0, 0x7FFFF       # t0 = 0x7FFFF000
    addi  t0, t0, 0x7FF     # t0 = 0x7FFFFFFF (INT_MAX - some)
    sw    t0, 0(s2)
    addi  t1, zero, 1
    amoadd.w t2, t1, (s2)  # t2 = old, M = old + 1 (wraps)
    bne   t2, t0, fail_15

    # ===== Test 16: SC.W to different address than LR.W fails =====
    addi  t0, zero, 10
    sw    t0, 0(s2)         # M[0x1000] = 10
    lr.w  t1, (s2)          # reservation at 0x1000
    addi  t2, zero, 99
    addi  s3, s2, 4         # s3 = 0x1004 (different address)
    sw    zero, 0(s3)       # M[0x1004] = 0
    sc.w  t3, t2, (s3)      # SC to 0x1004, reservation was at 0x1000 → fail
    addi  t4, zero, 1
    bne   t3, t4, fail_16   # t3 must be 1 (failure)
    lw    t5, 0(s3)
    bne   t5, zero, fail_16 # M[0x1004] must still be 0 (store didn't happen)

    # ===== Test 17: AMOMIN.W with boundary values (0x80000000 vs 0x7FFFFFFF) =====
    lui   t0, 0x80000       # t0 = 0x80000000 (INT_MIN)
    sw    t0, 0(s2)
    lui   t1, 0x7FFFF
    addi  t1, t1, 0x7FF     # t1 = 0x7FFFFFFF (INT_MAX)
    amomin.w t2, t1, (s2)   # t2 = old(INT_MIN), M = min(INT_MIN, INT_MAX) = INT_MIN
    bne   t2, t0, fail_17   # t2 must be 0x80000000
    lw    t3, 0(s2)
    bne   t3, t0, fail_17   # M must still be 0x80000000

    # ===== Test 18: AMOMAX.W with boundary values (0x80000000 vs 0x7FFFFFFF) =====
    lui   t0, 0x80000       # t0 = 0x80000000 (INT_MIN)
    sw    t0, 0(s2)
    lui   t1, 0x7FFFF
    addi  t1, t1, 0x7FF     # t1 = 0x7FFFFFFF (INT_MAX)
    amomax.w t2, t1, (s2)   # t2 = old(INT_MIN), M = max(INT_MIN, INT_MAX) = INT_MAX
    bne   t2, t0, fail_18   # t2 must be 0x80000000
    lw    t3, 0(s2)
    bne   t3, t1, fail_18   # M must be 0x7FFFFFFF

    # ===== Test 19: AMOMINU.W with 0x00000000 vs 0xFFFFFFFF =====
    sw    zero, 0(s2)       # M[0x1000] = 0
    addi  t1, zero, -1      # t1 = 0xFFFFFFFF
    amominu.w t2, t1, (s2)  # t2 = old(0), M = minu(0, 0xFFFFFFFF) = 0
    bne   t2, zero, fail_19 # t2 must be 0
    lw    t3, 0(s2)
    bne   t3, zero, fail_19 # M must still be 0

    # ===== Test 20: AMOMAXU.W with 0x00000000 vs 0xFFFFFFFF =====
    sw    zero, 0(s2)       # M[0x1000] = 0
    addi  t1, zero, -1      # t1 = 0xFFFFFFFF
    amomaxu.w t2, t1, (s2)  # t2 = old(0), M = maxu(0, 0xFFFFFFFF) = 0xFFFFFFFF
    bne   t2, zero, fail_20 # t2 must be 0
    lw    t3, 0(s2)
    bne   t3, t1, fail_20   # M must be 0xFFFFFFFF

    # ===== Test 21: Reservation invalidated by SB to reserved word =====
    addi  t0, zero, 42
    sw    t0, 0(s2)         # M[0x1000] = 42
    lr.w  t1, (s2)          # reservation at 0x1000
    addi  t2, zero, 0xFF
    sb    t2, 0(s2)         # byte store to same word → invalidates reservation
    addi  t3, zero, 99
    sc.w  t4, t3, (s2)      # should fail (reservation cleared by sb)
    addi  t5, zero, 1
    bne   t4, t5, fail_21

    # ===== Test 22: Reservation invalidated by SH to reserved word =====
    addi  t0, zero, 42
    sw    t0, 0(s2)
    lr.w  t1, (s2)          # reservation at 0x1000
    addi  t2, zero, 0x123
    sh    t2, 0(s2)         # halfword store → invalidates reservation
    addi  t3, zero, 99
    sc.w  t4, t3, (s2)      # should fail
    addi  t5, zero, 1
    bne   t4, t5, fail_22

    # SUCCESS
    addi  a0, zero, 0
    ecall

fail_1:  addi a0, zero, 1;  ecall
fail_2:  addi a0, zero, 2;  ecall
fail_3:  addi a0, zero, 3;  ecall
fail_4:  addi a0, zero, 4;  ecall
fail_5:  addi a0, zero, 5;  ecall
fail_6:  addi a0, zero, 6;  ecall
fail_7:  addi a0, zero, 7;  ecall
fail_8:  addi a0, zero, 8;  ecall
fail_9:  addi a0, zero, 9;  ecall
fail_10: addi a0, zero, 10; ecall
fail_11: addi a0, zero, 11; ecall
fail_12: addi a0, zero, 12; ecall
fail_13: addi a0, zero, 13; ecall
fail_14: addi a0, zero, 14; ecall
fail_15: addi a0, zero, 15; ecall
fail_16: addi a0, zero, 16; ecall
fail_17: addi a0, zero, 17; ecall
fail_18: addi a0, zero, 18; ecall
fail_19: addi a0, zero, 19; ecall
fail_20: addi a0, zero, 20; ecall
fail_21: addi a0, zero, 21; ecall
fail_22: addi a0, zero, 22; ecall
