# RV32I Basic Instruction Test
# Tests all base integer instructions
# Result: x10 (a0) = 0 on success, test number on failure

.section .text.init
.globl _start
_start:
    # Setup stack pointer
    lui   sp, 0x10        # sp = 0x10000 (top of 64KB)
    addi  sp, sp, -16     # sp = 0xFFF0

    # ===== Test 1: LUI =====
    lui   t0, 0xDEADB
    lui   t1, 0xDEADB
    bne   t0, t1, fail_1

    # ===== Test 2: AUIPC =====
    auipc t0, 0           # t0 = PC of this instruction
    addi  t1, t0, 8       # expected: PC+8 (skip AUIPC+ADDI, both 4B)
    auipc t2, 0
    bne   t1, t2, fail_2

    # ===== Test 3: ADDI =====
    addi  t0, zero, 42
    addi  t1, zero, 42
    bne   t0, t1, fail_3
    # Negative immediate
    addi  t0, zero, -1
    addi  t1, zero, -1
    bne   t0, t1, fail_3

    # ===== Test 4: SLTI =====
    addi  t0, zero, -5
    slti  t1, t0, 0       # -5 < 0 → 1
    addi  t2, zero, 1
    bne   t1, t2, fail_4
    slti  t1, t0, -10     # -5 < -10 → 0
    bne   t1, zero, fail_4

    # ===== Test 5: SLTIU =====
    addi  t0, zero, 5
    sltiu t1, t0, 10      # 5 <u 10 → 1
    addi  t2, zero, 1
    bne   t1, t2, fail_5
    sltiu t1, t0, 3       # 5 <u 3 → 0
    bne   t1, zero, fail_5

    # ===== Test 6: XORI =====
    addi  t0, zero, 0xFF
    xori  t1, t0, 0x0F    # 0xFF ^ 0x0F = 0xF0
    addi  t2, zero, 0xF0
    bne   t1, t2, fail_6

    # ===== Test 7: ORI =====
    addi  t0, zero, 0xF0
    ori   t1, t0, 0x0F    # 0xF0 | 0x0F = 0xFF
    addi  t2, zero, 0xFF
    bne   t1, t2, fail_7

    # ===== Test 8: ANDI =====
    addi  t0, zero, 0xFF
    andi  t1, t0, 0x0F    # 0xFF & 0x0F = 0x0F
    addi  t2, zero, 0x0F
    bne   t1, t2, fail_8

    # ===== Test 9: SLLI =====
    addi  t0, zero, 1
    slli  t1, t0, 10      # 1 << 10 = 1024
    addi  t2, zero, 1024
    bne   t1, t2, fail_9

    # ===== Test 10: SRLI =====
    lui   t0, 0x80000     # t0 = 0x80000000
    srli  t1, t0, 1       # 0x80000000 >> 1 = 0x40000000
    lui   t2, 0x40000
    bne   t1, t2, fail_10

    # ===== Test 11: SRAI =====
    lui   t0, 0x80000     # t0 = 0x80000000 (negative)
    srai  t1, t0, 4       # arithmetic right shift by 4
    lui   t2, 0xF8000     # expected: 0xF8000000
    bne   t1, t2, fail_11

    # ===== Test 12: ADD =====
    addi  t0, zero, 100
    addi  t1, zero, 200
    add   t2, t0, t1
    addi  t3, zero, 300
    bne   t2, t3, fail_12

    # ===== Test 13: SUB =====
    addi  t0, zero, 200
    addi  t1, zero, 100
    sub   t2, t0, t1
    addi  t3, zero, 100
    bne   t2, t3, fail_13

    # ===== Test 14: SLT =====
    addi  t0, zero, -1
    addi  t1, zero, 1
    slt   t2, t0, t1      # -1 < 1 → 1
    addi  t3, zero, 1
    bne   t2, t3, fail_14

    # ===== Test 15: SLTU =====
    addi  t0, zero, 1
    addi  t1, zero, -1    # -1 = 0xFFFFFFFF unsigned
    sltu  t2, t0, t1      # 1 <u 0xFFFFFFFF → 1
    addi  t3, zero, 1
    bne   t2, t3, fail_15

    # ===== Test 16: XOR =====
    addi  t0, zero, 0xFF
    addi  t1, zero, 0x0F
    xor   t2, t0, t1      # 0xFF ^ 0x0F = 0xF0
    addi  t3, zero, 0xF0
    bne   t2, t3, fail_16

    # ===== Test 17: OR =====
    addi  t0, zero, 0xF0
    addi  t1, zero, 0x0F
    or    t2, t0, t1
    addi  t3, zero, 0xFF
    bne   t2, t3, fail_17

    # ===== Test 18: AND =====
    addi  t0, zero, 0xFF
    addi  t1, zero, 0x0F
    and   t2, t0, t1
    addi  t3, zero, 0x0F
    bne   t2, t3, fail_18

    # ===== Test 19: SLL =====
    addi  t0, zero, 1
    addi  t1, zero, 10
    sll   t2, t0, t1
    addi  t3, zero, 1024
    bne   t2, t3, fail_19

    # ===== Test 20: SRL =====
    lui   t0, 0x80000
    addi  t1, zero, 1
    srl   t2, t0, t1      # logical shift right
    lui   t3, 0x40000
    bne   t2, t3, fail_20

    # ===== Test 21: SRA =====
    lui   t0, 0x80000     # negative
    addi  t1, zero, 4
    sra   t2, t0, t1
    lui   t3, 0xF8000
    bne   t2, t3, fail_21

    # ===== Test 22: SW/LW =====
    addi  t0, zero, 0x42
    lui   t1, 0x1         # address 0x1000
    sw    t0, 0(t1)
    lw    t2, 0(t1)
    bne   t0, t2, fail_22

    # ===== Test 23: SB/LB/LBU =====
    addi  t0, zero, -128  # 0x80
    sb    t0, 4(t1)
    lb    t2, 4(t1)       # sign-extended → -128
    bne   t0, t2, fail_23
    lbu   t3, 4(t1)       # zero-extended → 128
    addi  t4, zero, 128
    bne   t3, t4, fail_23

    # ===== Test 24: SH/LH/LHU =====
    lui   t0, 0xFFFFF     # t0 = 0xFFFFF000
    addi  t0, t0, 0x100   # t0 = 0xFFFFF100 → store lower 16: 0xF100
    sh    t0, 8(t1)
    lh    t2, 8(t1)       # sign-extended
    lhu   t3, 8(t1)       # zero-extended

    # ===== Test 25: BEQ =====
    addi  t0, zero, 5
    addi  t1, zero, 5
    beq   t0, t1, test_25_pass
    j     fail_25
test_25_pass:

    # ===== Test 26: BNE =====
    addi  t0, zero, 5
    addi  t1, zero, 6
    bne   t0, t1, test_26_pass
    j     fail_26
test_26_pass:

    # ===== Test 27: BLT =====
    addi  t0, zero, -1
    addi  t1, zero, 0
    blt   t0, t1, test_27_pass
    j     fail_27
test_27_pass:

    # ===== Test 28: BGE =====
    addi  t0, zero, 5
    addi  t1, zero, 5
    bge   t0, t1, test_28_pass
    j     fail_28
test_28_pass:

    # ===== Test 29: BLTU/BGEU =====
    addi  t0, zero, 1
    addi  t1, zero, -1   # large unsigned
    bltu  t0, t1, test_29_pass
    j     fail_29
test_29_pass:

    # ===== Test 30: JAL =====
    jal   ra, test_30_target
    j     fail_30
test_30_target:
    # ra should be return address (PC of j fail_30)
    # Verify ra is set (not zero)
    beq   ra, zero, fail_30

    # ===== Test 31: JALR =====
    la    t0, test_31_target
    jalr  ra, t0, 0
    j     fail_31
test_31_target:
    beq   ra, zero, fail_31

    # ===== ALL PASSED =====
    addi  a0, zero, 0     # a0 = 0 → success
    ecall

    # Fail handlers
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
fail_23: addi a0, zero, 23; ecall
fail_25: addi a0, zero, 25; ecall
fail_26: addi a0, zero, 26; ecall
fail_27: addi a0, zero, 27; ecall
fail_28: addi a0, zero, 28; ecall
fail_29: addi a0, zero, 29; ecall
fail_30: addi a0, zero, 30; ecall
fail_31: addi a0, zero, 31; ecall
