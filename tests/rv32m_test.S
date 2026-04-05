# RV32M Extension Test — Multiply/Divide
# a0 = 0 on success, test number on failure

.section .text.init
.globl _start
_start:
    # ===== MUL =====
    # Test 1: 6 * 7 = 42
    addi  t0, zero, 6
    addi  t1, zero, 7
    mul   t2, t0, t1
    addi  t3, zero, 42
    bne   t2, t3, fail_1

    # Test 2: -1 * -1 = 1 (lower 32 bits)
    addi  t0, zero, -1
    addi  t1, zero, -1
    mul   t2, t0, t1
    addi  t3, zero, 1
    bne   t2, t3, fail_2

    # Test 3: 0 * anything = 0
    mul   t2, zero, t0
    bne   t2, zero, fail_3

    # ===== MULH (signed * signed, upper 32) =====
    # Test 4: -1 * 2 → upper = -1
    addi  t0, zero, -1
    addi  t1, zero, 2
    mulh  t2, t0, t1
    addi  t3, zero, -1
    bne   t2, t3, fail_4

    # Test 5: small positive * small positive → upper = 0
    addi  t0, zero, 100
    addi  t1, zero, 200
    mulh  t2, t0, t1
    bne   t2, zero, fail_5

    # ===== MULHU (unsigned * unsigned, upper 32) =====
    # Test 6: 0xFFFFFFFF * 0xFFFFFFFF upper = 0xFFFFFFFE
    addi  t0, zero, -1    # 0xFFFFFFFF
    addi  t1, zero, -1
    mulhu t2, t0, t1
    addi  t3, zero, -2    # 0xFFFFFFFE
    bne   t2, t3, fail_6

    # ===== MULHSU (signed * unsigned, upper 32) =====
    # Test 7: -1(signed) * 2(unsigned) upper = -1
    addi  t0, zero, -1
    addi  t1, zero, 2
    mulhsu t2, t0, t1
    addi  t3, zero, -1
    bne   t2, t3, fail_7

    # ===== DIV =====
    # Test 8: 42 / 6 = 7
    addi  t0, zero, 42
    addi  t1, zero, 6
    div   t2, t0, t1
    addi  t3, zero, 7
    bne   t2, t3, fail_8

    # Test 9: Division by zero → -1
    addi  t0, zero, 42
    div   t2, t0, zero
    addi  t3, zero, -1
    bne   t2, t3, fail_9

    # Test 10: -6 / 2 = -3
    addi  t0, zero, -6
    addi  t1, zero, 2
    div   t2, t0, t1
    addi  t3, zero, -3
    bne   t2, t3, fail_10

    # Test 11: Overflow: 0x80000000 / -1 = 0x80000000
    lui   t0, 0x80000     # INT32_MIN
    addi  t1, zero, -1
    div   t2, t0, t1
    bne   t2, t0, fail_11

    # ===== DIVU =====
    # Test 12: 42 / 6 = 7
    addi  t0, zero, 42
    addi  t1, zero, 6
    divu  t2, t0, t1
    addi  t3, zero, 7
    bne   t2, t3, fail_12

    # Test 13: DIVU by zero → 0xFFFFFFFF
    addi  t0, zero, 42
    divu  t2, t0, zero
    addi  t3, zero, -1
    bne   t2, t3, fail_13

    # ===== REM =====
    # Test 14: 7 % 2 = 1
    addi  t0, zero, 7
    addi  t1, zero, 2
    rem   t2, t0, t1
    addi  t3, zero, 1
    bne   t2, t3, fail_14

    # Test 15: -7 % 2 = -1
    addi  t0, zero, -7
    addi  t1, zero, 2
    rem   t2, t0, t1
    addi  t3, zero, -1
    bne   t2, t3, fail_15

    # Test 16: REM by zero → dividend
    addi  t0, zero, 42
    rem   t2, t0, zero
    bne   t2, t0, fail_16

    # ===== REMU =====
    # Test 17: 7 %u 2 = 1
    addi  t0, zero, 7
    addi  t1, zero, 2
    remu  t2, t0, t1
    addi  t3, zero, 1
    bne   t2, t3, fail_17

    # Test 18: REMU by zero → dividend
    addi  t0, zero, 42
    remu  t2, t0, zero
    bne   t2, t0, fail_18

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
