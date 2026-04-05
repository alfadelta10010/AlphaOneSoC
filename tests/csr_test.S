# Zicsr Extension Test — CSR read/write/set/clear
# a0 = 0 on success, test number on failure

.section .text.init
.globl _start
_start:
    # ===== Test 1: CSRRW mscratch =====
    addi  t0, zero, 0x42
    csrrw t1, mscratch, t0    # write 0x42 to mscratch, t1=old value(0)
    bne   t1, zero, fail_1
    csrr  t2, mscratch        # read back
    addi  t3, zero, 0x42
    bne   t2, t3, fail_1

    # ===== Test 2: CSRRS set bits =====
    addi  t0, zero, 0x0F
    csrrw zero, mscratch, t0  # mscratch = 0x0F
    addi  t0, zero, 0xF0
    csrrs t1, mscratch, t0    # set bits: 0x0F | 0xF0 = 0xFF, t1=old(0x0F)
    addi  t2, zero, 0x0F
    bne   t1, t2, fail_2
    csrr  t3, mscratch
    addi  t4, zero, 0xFF
    bne   t3, t4, fail_2

    # ===== Test 3: CSRRC clear bits =====
    addi  t0, zero, 0x0F
    csrrc t1, mscratch, t0    # clear bits: 0xFF & ~0x0F = 0xF0, t1=old(0xFF)
    addi  t2, zero, 0xFF
    bne   t1, t2, fail_3
    csrr  t3, mscratch
    addi  t4, zero, 0xF0
    bne   t3, t4, fail_3

    # ===== Test 4: CSRRWI =====
    csrrwi t1, mscratch, 0x1F # write zimm=31 to mscratch
    csrr  t2, mscratch
    addi  t3, zero, 31
    bne   t2, t3, fail_4

    # ===== Test 5: CSRRSI =====
    csrrwi zero, mscratch, 0  # clear mscratch
    csrrsi t1, mscratch, 0x0F # set bits: 0 | 0x0F = 0x0F
    bne   t1, zero, fail_5    # old value should be 0
    csrr  t2, mscratch
    addi  t3, zero, 0x0F
    bne   t2, t3, fail_5

    # ===== Test 6: CSRRCI =====
    csrrci t1, mscratch, 0x05 # clear bits: 0x0F & ~0x05 = 0x0A
    addi  t2, zero, 0x0F
    bne   t1, t2, fail_6
    csrr  t3, mscratch
    addi  t4, zero, 0x0A
    bne   t3, t4, fail_6

    # ===== Test 7: Read mhartid (should be 0) =====
    csrr  t0, mhartid
    bne   t0, zero, fail_7

    # ===== Test 8: Read misa =====
    csrr  t0, misa
    # Check XLEN=32: bits[31:30]=01
    srli  t1, t0, 30
    addi  t2, zero, 1
    bne   t1, t2, fail_8
    # Check I extension: bit 8
    andi  t1, t0, 0x100
    beq   t1, zero, fail_8

    # ===== Test 9: mcycle counter incrementing =====
    csrr  t0, mcycle
    nop
    nop
    nop
    csrr  t1, mcycle
    beq   t0, t1, fail_9    # should have advanced

    # ===== Test 10: mtvec write/read =====
    lui   t0, 0x1           # 0x1000
    csrrw zero, mtvec, t0
    csrr  t1, mtvec
    bne   t0, t1, fail_10

    # ===== Test 11: mepc write/read (bit 0 cleared) =====
    addi  t0, zero, 0xFF   # 0xFF → bit 0 should be cleared → 0xFE
    csrrw zero, mepc, t0
    csrr  t1, mepc
    addi  t2, zero, 0xFE
    bne   t1, t2, fail_11

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
