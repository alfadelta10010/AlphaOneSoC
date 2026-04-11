# RV32C illegal compressed instruction tests — CPU-level trap verification
# a0 = 0 on success, test number on failure
#
# Tests that illegal compressed encodings trap as illegal instructions (mcause=2)
# at the CPU level, not just in the standalone compressed decoder.
#
# Registers:
#   s2 = expected mcause (always 2 for illegal instruction)
#   s3 = actual mcause captured by trap handler
#   s4 = trap handler ran flag

.section .text.init
.globl _start

.option push
.option norvc              # Setup uses 32-bit instructions

_start:
    # Setup trap handler
    la    t0, trap_handler
    csrw  mtvec, t0
    addi  a0, zero, 0
    addi  s2, zero, 2      # Expected mcause for all tests

    # ===== Test 1: All-zero halfword (C.ADDI4SPN with nzuimm=0) =====
    addi  s4, zero, 0
    .half 0x0000
    .half 0x0000            # Padding to maintain 4-byte alignment for next instr
    addi  t0, zero, 1
    bne   s4, t0, fail_1
    bne   s3, s2, fail_1

    # ===== Test 2: Reserved Quadrant 0 funct3=001 (C.FLD, not in RV32IMAC) =====
    addi  s4, zero, 0
    .half 0x2000            # Q0, funct3=001, rest=0
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_2
    bne   s3, s2, fail_2

    # ===== Test 3: Reserved Quadrant 0 funct3=011 (C.FLW/C.FLD, not in RV32IMAC) =====
    addi  s4, zero, 0
    .half 0x6000            # Q0, funct3=011
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_3
    bne   s3, s2, fail_3

    # ===== Test 4: Reserved Quadrant 0 funct3=101 (C.FSD, not in RV32IMAC) =====
    addi  s4, zero, 0
    .half 0xA000            # Q0, funct3=101
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_4
    bne   s3, s2, fail_4

    # ===== Test 5: Reserved Quadrant 0 funct3=111 (C.FSW/C.FSD, not in RV32IMAC) =====
    addi  s4, zero, 0
    .half 0xE000            # Q0, funct3=111
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_5
    bne   s3, s2, fail_5

    # ===== Test 6: C.LWSP with rd=x0 (illegal per spec) =====
    addi  s4, zero, 0
    .half 0x4002            # Q2, funct3=010, rd=0 → illegal C.LWSP
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_6
    bne   s3, s2, fail_6

    # ===== Test 7: C.JR with rs1=x0 (illegal per spec) =====
    addi  s4, zero, 0
    .half 0x8002            # Q2, funct3=100, bit12=0, rd=0, rs2=0 → C.JR x0 illegal
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_7
    bne   s3, s2, fail_7

    # ===== Test 8: Reserved Q2 funct3=001 (C.FLDSP, not in RV32IMAC) =====
    addi  s4, zero, 0
    .half 0x2002            # Q2, funct3=001
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_8
    bne   s3, s2, fail_8

    # ===== Test 9: Reserved Q2 funct3=011 (C.FLWSP/FLDSP) =====
    addi  s4, zero, 0
    .half 0x6002            # Q2, funct3=011
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_9
    bne   s3, s2, fail_9

    # ===== Test 10: Reserved Q2 funct3=101 (C.FSDSP) =====
    addi  s4, zero, 0
    .half 0xA002            # Q2, funct3=101
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_10
    bne   s3, s2, fail_10

    # ===== Test 11: C.LUI with rd=x0 and nzimm=0 =====
    addi  s4, zero, 0
    .half 0x6001            # Q1, funct3=011, rd=0 → illegal
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_11
    bne   s3, s2, fail_11

    # ===== Test 12: C.ADDI16SP with nzimm=0 =====
    addi  s4, zero, 0
    .half 0x6101            # Q1, funct3=011, rd=2(sp), nzimm=0 → illegal
    .half 0x0000
    addi  t0, zero, 1
    bne   s4, t0, fail_12
    bne   s3, s2, fail_12

    # SUCCESS
    addi  a0, zero, 0
    j     .

# ---- Trap handler ----
.align 4
trap_handler:
    csrr  s3, mcause
    addi  s4, zero, 1
    csrr  t5, mepc
    # All trapping instructions are 16-bit compressed (2 bytes)
    # But we padded with .half 0x0000 which is also illegal, so
    # advance by 4 bytes to skip both the illegal halfword and padding
    addi  t5, t5, 4
    csrw  mepc, t5
    mret

fail_1:  addi a0, zero, 1;  j .
fail_2:  addi a0, zero, 2;  j .
fail_3:  addi a0, zero, 3;  j .
fail_4:  addi a0, zero, 4;  j .
fail_5:  addi a0, zero, 5;  j .
fail_6:  addi a0, zero, 6;  j .
fail_7:  addi a0, zero, 7;  j .
fail_8:  addi a0, zero, 8;  j .
fail_9:  addi a0, zero, 9;  j .
fail_10: addi a0, zero, 10; j .
fail_11: addi a0, zero, 11; j .
fail_12: addi a0, zero, 12; j .
.option pop
