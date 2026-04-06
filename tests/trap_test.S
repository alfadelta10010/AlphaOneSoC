# Trap handling tests — illegal instructions, misalignment, bad SYSTEM encodings
# a0 = 0 on success, test number on failure
#
# Strategy: set up mtvec to point at a trap handler that records mcause into
# a known register, then execute an instruction that should trap. After
# returning from the trap handler, verify mcause matched expectations.
#
# Registers:
#   s2 = expected mcause for the current test
#   s3 = actual mcause captured by trap handler
#   s4 = trap handler ran flag (0 = no trap, 1 = trapped)

.section .text.init
.globl _start

.option push
.option norvc              # Use 32-bit instructions for setup (avoid C interference)

_start:
    # ---- Setup trap handler ----
    la    t0, trap_handler
    csrw  mtvec, t0        # Direct mode: all traps go to trap_handler
    addi  a0, zero, 0

    # ===== Test 1: Illegal instruction traps with mcause=2 =====
    addi  s2, zero, 2      # Expected: illegal instruction
    addi  s4, zero, 0      # Clear flag
    .word 0x00000000        # All-zeros is an illegal 32-bit instruction
    # Trap handler should have run, returned here
    addi  t0, zero, 1
    bne   s4, t0, fail_1   # Trap handler must have fired
    bne   s3, s2, fail_1   # mcause must be 2

    # ===== Test 2: ECALL traps with mcause=11 =====
    addi  s2, zero, 11     # Expected: environment call from M-mode
    addi  s4, zero, 0
    ecall
    addi  t0, zero, 1
    bne   s4, t0, fail_2
    bne   s3, s2, fail_2

    # ===== Test 3: EBREAK traps with mcause=3 =====
    addi  s2, zero, 3      # Expected: breakpoint
    addi  s4, zero, 0
    ebreak
    addi  t0, zero, 1
    bne   s4, t0, fail_3
    bne   s3, s2, fail_3

    # ===== Test 4: Misaligned LW traps with mcause=4 (load address misaligned) =====
    addi  s2, zero, 4      # Expected: load address misaligned
    addi  s4, zero, 0
    lui   t0, 0x1          # t0 = 0x1000
    addi  t0, t0, 1        # t0 = 0x1001 (misaligned for LW)
    lw    t1, 0(t0)        # Should trap
    addi  t0, zero, 1
    bne   s4, t0, fail_4
    bne   s3, s2, fail_4

    # ===== Test 5: Misaligned SW traps with mcause=6 (store address misaligned) =====
    addi  s2, zero, 6      # Expected: store/AMO address misaligned
    addi  s4, zero, 0
    lui   t0, 0x1
    addi  t0, t0, 3        # t0 = 0x1003 (misaligned for SW)
    sw    t1, 0(t0)        # Should trap
    addi  t0, zero, 1
    bne   s4, t0, fail_5
    bne   s3, s2, fail_5

    # ===== Test 6: Misaligned LH traps with mcause=4 =====
    addi  s2, zero, 4      # Expected: load address misaligned
    addi  s4, zero, 0
    lui   t0, 0x1
    addi  t0, t0, 1        # t0 = 0x1001 (misaligned for LH)
    lh    t1, 0(t0)        # Should trap
    addi  t0, zero, 1
    bne   s4, t0, fail_6
    bne   s3, s2, fail_6

    # ===== Test 7: Misaligned SH traps with mcause=6 =====
    addi  s2, zero, 6      # Expected: store/AMO address misaligned
    addi  s4, zero, 0
    lui   t0, 0x1
    addi  t0, t0, 1        # t0 = 0x1001 (misaligned for SH)
    sh    t1, 0(t0)        # Should trap
    addi  t0, zero, 1
    bne   s4, t0, fail_7
    bne   s3, s2, fail_7

    # ===== Test 8: Aligned LB does NOT trap =====
    # (Sanity check: byte loads should work at any alignment)
    lui   t0, 0x1
    addi  t0, t0, 3        # t0 = 0x1003 (any byte alignment is fine)
    addi  s4, zero, 0
    lb    t1, 0(t0)        # Should NOT trap
    bne   s4, zero, fail_8 # s4 must still be 0

    # ===== Test 9: Reserved SYSTEM encoding traps as illegal =====
    addi  s2, zero, 2      # Expected: illegal instruction
    addi  s4, zero, 0
    # Encode: opcode=1110011, funct3=000, funct7=0000010 (reserved), rd=0, rs1=0, rs2=0
    # imm[11:0] = 0000010_00000 = 0x040
    # Full encoding: imm[11:0]=0x040, rs1=0, funct3=000, rd=0, opcode=1110011
    # = 0x04000073
    .word 0x04000073
    addi  t0, zero, 1
    bne   s4, t0, fail_9
    bne   s3, s2, fail_9

    # ===== Test 10: WFI does NOT trap (treated as NOP in M-mode) =====
    addi  s4, zero, 0
    # WFI encoding: 0x10500073
    .word 0x10500073
    bne   s4, zero, fail_10  # Must NOT have trapped

    # ===== Test 11: Read from non-existent CSR traps as illegal =====
    addi  s2, zero, 2      # Expected: illegal instruction
    addi  s4, zero, 0
    # CSRRS x5, 0xFFF, x0 — read-only access to non-existent CSR 0xFFF
    # Encoding: imm=0xFFF, rs1=0, funct3=010, rd=5, opcode=1110011
    # = FFF_00000_010_00101_1110011
    .word 0xFFF02273
    addi  t0, zero, 1
    bne   s4, t0, fail_11
    bne   s3, s2, fail_11

    # ===== Test 12: Write to read-only CSR traps as illegal =====
    addi  s2, zero, 2      # Expected: illegal instruction
    addi  s4, zero, 0
    # CSRRW x0, mhartid(0xF14), x5 — write to read-only CSR
    # Encoding: imm=0xF14, rs1=5, funct3=001, rd=0, opcode=1110011
    .word 0xF1429073
    addi  t0, zero, 1
    bne   s4, t0, fail_12
    bne   s3, s2, fail_12

    # ===== Test 13: Read-only access to read-only CSR does NOT trap =====
    # CSRRS x5, mhartid(0xF14), x0 — rs1=0 means read-only, should NOT trap
    addi  s4, zero, 0
    csrr  t0, 0xF14        # csrr is pseudo for csrrs rd, csr, x0
    bne   s4, zero, fail_13 # Must NOT have trapped

    # SUCCESS
    addi  a0, zero, 0
    j     .             # Halt loop — testbench detects and terminates

# ---- Trap handler ----
# Saves mcause to s3, sets s4=1, advances mepc past the trapping instruction,
# then returns with mret.
.align 4
trap_handler:
    csrr  s3, mcause       # Read cause
    addi  s4, zero, 1      # Flag: trap occurred
    csrr  t5, mepc
    # Determine instruction length at mepc to skip past it.
    # Load the halfword at mepc: if bits [1:0] != 11, it's 16-bit (compressed).
    # We can't easily load from mepc here without clobbering more state,
    # so conservatively advance by 4 (all our test trapping instructions are 32-bit).
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
fail_13: addi a0, zero, 13; j .
.option pop
