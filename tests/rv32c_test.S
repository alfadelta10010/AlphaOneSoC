# RV32C Compressed Extension Test
# a0 = 0 on success, test number on failure
# Must be compiled with -march=rv32imac to enable compressed instructions

.section .text.init
.globl _start
.option push
.option norvc
_start:
    # Setup in non-compressed mode first
    lui   sp, 0x1          # sp = 0x1000 (safe address in data area)
    addi  sp, sp, -16      # sp = 0xFF0
    addi  a0, zero, 0

.option pop
    # Now allow compressed instructions

    # ===== Test 1: C.LI =====
    c.li  t0, 10           # t0 = 10
    addi  t1, zero, 10
    bne   t0, t1, fail_1

    # ===== Test 2: C.LI negative =====
    c.li  t0, -5           # t0 = -5
    addi  t1, zero, -5
    bne   t0, t1, fail_2

    # ===== Test 3: C.MV =====
    addi  t0, zero, 42
    c.mv  t1, t0           # t1 = t0 = 42
    addi  t2, zero, 42
    bne   t1, t2, fail_3

    # ===== Test 4: C.ADD =====
    addi  t0, zero, 10
    addi  t1, zero, 20
    c.add t0, t1            # t0 = 10 + 20 = 30
    addi  t2, zero, 30
    bne   t0, t2, fail_4

    # ===== Test 5: C.ADDI =====
    addi  t0, zero, 5
    c.addi t0, 7            # t0 = 5 + 7 = 12
    addi  t1, zero, 12
    bne   t0, t1, fail_5

    # ===== Test 6: C.SLLI =====
    addi  t0, zero, 1
    c.slli t0, 4            # t0 = 1 << 4 = 16
    addi  t1, zero, 16
    bne   t0, t1, fail_6

    # ===== Test 7: C.SRLI (uses s0=x8) =====
    addi  s0, zero, 256    # 0x100
    c.srli s0, 4            # 0x100 >> 4 = 0x10
    addi  t1, zero, 16
    bne   s0, t1, fail_7

    # ===== Test 8: C.SRAI =====
    lui   s0, 0xFFFFF       # s0 = 0xFFFFF000 (negative)
    c.srai s0, 4            # arithmetic >> 4 = 0xFFFFFF00
    # 0xFFFFF000 >>> 4 = 0xFFFFFF00
    # Just verify the result is negative (sign preserved)
    addi  t1, zero, -256    # t1 = 0xFFFFFF00
    bne   s0, t1, fail_8

    # ===== Test 9: C.ANDI =====
    addi  s0, zero, 0xFF
    c.andi s0, 0x0F         # 0xFF & 0x0F = 0x0F
    addi  t1, zero, 0x0F
    bne   s0, t1, fail_9

    # ===== Test 10: C.SUB =====
    addi  s0, zero, 30
    addi  s1, zero, 10
    c.sub s0, s1             # s0 = 30 - 10 = 20
    addi  t1, zero, 20
    bne   s0, t1, fail_10

    # ===== Test 11: C.XOR =====
    addi  s0, zero, 0xFF
    addi  s1, zero, 0x0F
    c.xor s0, s1             # 0xFF ^ 0x0F = 0xF0
    addi  t1, zero, 0xF0
    bne   s0, t1, fail_11

    # ===== Test 12: C.OR =====
    addi  s0, zero, 0xF0
    addi  s1, zero, 0x0F
    c.or  s0, s1
    addi  t1, zero, 0xFF
    bne   s0, t1, fail_12

    # ===== Test 13: C.AND =====
    addi  s0, zero, 0xFF
    addi  s1, zero, 0x0F
    c.and s0, s1
    addi  t1, zero, 0x0F
    bne   s0, t1, fail_13

    # ===== Test 14: C.SWSP / C.LWSP =====
    addi  t0, zero, 0x55
    c.swsp t0, 0(sp)
    c.lwsp t1, 0(sp)
    bne   t0, t1, fail_14

    # ===== Test 15: C.SW / C.LW =====
    addi  s0, zero, 0x77
    addi  s1, sp, 0         # base address
    c.sw  s0, 4(s1)
    c.lw  s0, 4(s1)
    addi  t1, zero, 0x77
    bne   s0, t1, fail_15

    # ===== Test 16: C.J =====
    c.j   test_16_pass
    j     fail_16
test_16_pass:

    # ===== Test 17: C.JAL =====
    c.jal test_17_target
    j     fail_17
test_17_target:
    beq   ra, zero, fail_17

    # ===== Test 18: C.JR =====
    la    t0, test_18_pass
    c.jr  t0
    j     fail_18
test_18_pass:

    # ===== Test 19: C.JALR =====
    la    t0, test_19_target
    c.jalr t0
    j     fail_19
test_19_target:
    beq   ra, zero, fail_19

    # ===== Test 20: C.BEQZ =====
    addi  s0, zero, 0
    c.beqz s0, test_20_pass
    j     fail_20
test_20_pass:

    # ===== Test 21: C.BNEZ =====
    addi  s0, zero, 1
    c.bnez s0, test_21_pass
    j     fail_21
test_21_pass:

    # ===== Test 22: C.NOP =====
    c.nop
    # If we get here, NOP worked

    # ===== Test 23: C.LUI =====
    c.lui t0, 0x1F         # t0 = 0x1F000
    lui   t1, 0x1F
    bne   t0, t1, fail_23

    # ===== Test 24: C.ADDI16SP =====
    addi  t0, sp, 0        # save sp
    c.addi16sp sp, 32      # sp += 32
    addi  t1, t0, 32
    bne   sp, t1, fail_24
    addi  sp, t0, 0        # restore sp

    # SUCCESS
    addi  a0, zero, 0
    ecall

.option push
.option norvc
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
fail_23: addi a0, zero, 23; ecall
fail_24: addi a0, zero, 24; ecall
.option pop
