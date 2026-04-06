# Pipeline hazard tests — forwarding, stalls, flushes
# a0 = 0 on success, test number on failure
#
# Tests exercise the 3-stage pipeline's hazard handling:
#   - WB→EX data forwarding (ALU result, load result)
#   - Load-use stall (1 cycle bubble)
#   - Branch flush (instruction after taken branch must not retire)
#   - CSR write→read forwarding
#   - Jump-link consumer (use ra immediately after JAL/JALR)

.section .text.init
.globl _start

.option push
.option norvc

_start:
    addi  a0, zero, 0

    # ===== Test 1: ALU→ALU forwarding on rs1 =====
    # ADD produces result in WB, next instruction uses it via rs1
    addi  t0, zero, 10      # t0 = 10
    addi  t1, t0, 5         # t1 = t0 + 5 = 15 (forwarded from WB)
    addi  t2, zero, 15
    bne   t1, t2, fail_1

    # ===== Test 2: ALU→ALU forwarding on rs2 =====
    addi  t0, zero, 20      # t0 = 20
    sub   t1, zero, t0      # t1 = 0 - t0 = -20 (rs2 forwarded)
    addi  t2, zero, -20
    bne   t1, t2, fail_2

    # ===== Test 3: ALU→ALU forwarding on both rs1 and rs2 =====
    addi  t0, zero, 7       # t0 = 7 (will be in WB when next instr is in EX)
    add   t1, t0, t0        # t1 = 7 + 7 = 14 (both operands forwarded)
    addi  t2, zero, 14
    bne   t1, t2, fail_3

    # ===== Test 4: Load-use stall =====
    # Store a value, load it back, use it immediately (requires stall)
    lui   t3, 0x1           # t3 = 0x1000
    addi  t0, zero, 42
    sw    t0, 0(t3)         # M[0x1000] = 42
    lw    t1, 0(t3)         # t1 = 42 (load result)
    addi  t2, t1, 8         # t2 = 42 + 8 = 50 (load-use: must stall 1 cycle)
    addi  t4, zero, 50
    bne   t2, t4, fail_4

    # ===== Test 5: Load→branch (load-use stall before branch) =====
    addi  t0, zero, 1
    sw    t0, 4(t3)         # M[0x1004] = 1
    lw    t1, 4(t3)         # t1 = 1
    beq   t1, t0, test5_ok  # Branch on loaded value (must stall then branch)
    j     fail_5
test5_ok:

    # ===== Test 6: Taken branch flushes following instruction =====
    # After a taken branch, the instruction at PC+4 must NOT execute
    addi  t0, zero, 99
    j     test6_target       # Unconditional jump
    addi  t0, zero, 0        # This must NOT execute (flushed)
test6_target:
    addi  t2, zero, 99
    bne   t0, t2, fail_6    # t0 must still be 99

    # ===== Test 7: JAL link register consumer =====
    # JAL writes PC+4 to rd; use rd immediately after
    jal   t0, test7_cont    # t0 = PC_jal + 4 = address of test7_cont
test7_cont:
    # t0 should equal the address of test7_cont
    auipc t1, 0             # t1 = PC of auipc = test7_cont address
    bne   t0, t1, fail_7

    # ===== Test 8: JALR link + forwarding =====
    la    t2, test8_cont
    jalr  t0, t2, 0         # t0 = PC_jalr + 4 = address of test8_cont
test8_cont:
    auipc t1, 0             # t1 = PC of auipc = test8_cont address
    bne   t0, t1, fail_8

    # ===== Test 9: CSR write→read forwarding =====
    # Write to mscratch, immediately read it back
    addi  t0, zero, 0x55
    csrw  mscratch, t0      # Write mscratch = 0x55
    csrr  t1, mscratch      # Read mscratch (must forward from WB)
    addi  t2, zero, 0x55
    bne   t1, t2, fail_9

    # ===== Test 10: Back-to-back CSR ops to different CSRs =====
    # Write mscratch, then read mtvec — no forwarding conflict
    addi  t0, zero, 0x77
    csrw  mscratch, t0
    csrr  t1, mtvec         # Different CSR — must NOT forward mscratch value
    # mtvec should be 0 (reset default, no trap handler set in this test)
    bne   t1, zero, fail_10

    # ===== Test 11: Store after taken branch must not execute =====
    lui   t3, 0x1           # t3 = 0x1000
    addi  t0, zero, 0
    sw    t0, 8(t3)         # M[0x1008] = 0
    addi  t0, zero, 1
    beq   t0, t0, test11_skip  # Always taken
    sw    t0, 8(t3)         # This store must NOT execute (flushed)
test11_skip:
    lw    t1, 8(t3)         # t1 should be 0 (store was flushed)
    bne   t1, zero, fail_11

    # ===== Test 12: Chain of 3 dependent ALU ops =====
    addi  t0, zero, 1       # t0 = 1
    addi  t1, t0, 1         # t1 = 2 (forwarded)
    addi  t2, t1, 1         # t2 = 3 (forwarded from t1 which was just produced)
    addi  t4, zero, 3
    bne   t2, t4, fail_12

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
.option pop
