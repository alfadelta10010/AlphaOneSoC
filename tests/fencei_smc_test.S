# FENCE.I self-modifying code test
#
# Verifies that a program can:
#   1. Write 32-bit instruction words into RAM.
#   2. Execute FENCE.I to serialise the instruction stream with the store.
#   3. Jump to and execute the freshly-written code.
#
# In simulation the memory model has no instruction cache, so FENCE.I is
# a pipeline flush.  This test validates the programming model and checks
# that the fencei_flush signal is asserted without breaking execution.
#
# A scratch area at 0x8080_0000, 8 MB into PSRAM, well clear of the test.  We write a small leaf function there:
#
#   leaf:
#     addi  a1, zero, 0x42   # a1 = 0x42
#     jalr  zero, ra, 0      # ret
#
# Then call it with:
#   jal   ra, leaf
#
# and verify a1 == 0x42 on return.
#
# Encoding of the instructions we'll store:
#   addi a1, zero, 0x42 → imm=0x42, rs1=x0, funct3=000, rd=x11, op=0010011
#                        = 0x04200593
#   jalr zero, ra, 0    → imm=0, rs1=x1, funct3=000, rd=x0, op=1100111
#                        = 0x00008067
#
# a0 = 0 on success.

.section .text.init
.globl _start

.option push
.option norvc

_start:
    addi  a0, zero, 0        # assume success

    # ===== Test 1: basic FENCE.I doesn't break state =====
    addi  t0, zero, 1
    fence.i
    addi  t1, zero, 1
    bne   t0, t1, fail_1

    # ===== Test 2: self-modifying code via RAM =====
    # Write two instructions to the scratch area (0x8080_0000 = 0x80800 << 12)
    # addi a1, zero, 0x42
    lui   t0, 0x80800        # t0 = 0x8080_0000 (scratch area)
    lui   t1, 0x04200        # upper bits of 0x04200593
    addi  t1, t1, 0x593      # t1 = 0x04200593  (addi a1, zero, 0x42)
    sw    t1, 0(t0)

    # jalr zero, ra, 0  (ret)
    addi  t1, zero, 0        # t1 = 0x00000000 first, then OR
    lui   t2, 0x00008        # 0x00008000
    addi  t2, t2, 0x067      # t2 = 0x00008067  (jalr zero, ra, 0)
    sw    t2, 4(t0)

    # Serialise: FENCE.I before executing the freshly-written code
    fence.i

    # Call the dynamic leaf function; ra gets return address
    jalr  ra, t0, 0          # call leaf at RAM base

    # Verify a1 == 0x42
    addi  t3, zero, 0x42
    bne   a1, t3, fail_2

    # ===== Test 3: FENCE.I between two stores to the same location =====
    # Overwrite leaf to return a1 = 0x7F instead
    lui   t0, 0x1000         # t0 = RAM base
    lui   t1, 0x07F00
    addi  t1, t1, 0x593      # addi a1, zero, 0x7F = 0x07F00593
    sw    t1, 0(t0)
    fence.i
    jalr  ra, t0, 0          # call updated leaf
    addi  t3, zero, 0x7F
    bne   a1, t3, fail_3

    # SUCCESS
    addi  a0, zero, 0
    j     .

fail_1: addi a0, zero, 1; j .
fail_2: addi a0, zero, 2; j .
fail_3: addi a0, zero, 3; j .

.option pop
