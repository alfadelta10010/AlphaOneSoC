# Gap probe for the rewritten datapath at the integration level: SRA/SRAI
# (serial, through muldiv's `sra` input), MULH/MULHSU/MULHU with negative
# operands (signed-aware shift-add), SLT/SLTU/SLTI/SLTIU across the sign
# boundary (shared comparator). No test in tests/directed runs these.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    li   a0, -8              # 0xFFFFFFF8
    li   a1, 0x80000000
    li   a2, 3
    li   a3, 31
    li   a4, 0x7FFFFFFF
    sra  s1, a0, a2          # -1
    sra  s2, a1, a3          # -1
    srai s3, a1, 4           # 0xF8000000
    srai s4, a4, 31          # 0
    sra  s5, a0, zero        # -8
    srl  s6, a0, a2          # 0x1FFFFFFF
    mulh   s7, a0, a0        # 0
    mulh   s8, a1, a1        # 0x40000000
    mulh   s9, a4, a0        # 0xFFFFFFFC
    mulhsu s10, a0, a4       # 0xFFFFFFFC
    mulhsu s11, a1, a0       # 0x80000004
    mulhu  t0, a0, a0        # 0xFFFFFFF0
    mulhu  t1, a1, a4        # 0x3FFFFFFF
    slt  t2, a0, a2          # 1
    sltu t3, a0, a2          # 0
    slti t4, a1, 0           # 1
    sltiu t5, a2, -1         # 1
    sltu t6, a2, a1          # 1
    li   s0, 1
    la   a5, tohost
    sw   s0, 0(a5)
1:  j 1b
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
