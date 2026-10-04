# Gap probe for the link address after the EX/WB consolidation: the link of a
# compressed jump-and-link is pc + 2, at a word-aligned and a halfword-aligned
# address (exwb_alu_result takes `pc`, i.e. ifex_pc + 2 for a 16-bit jump).
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
    la   a0, f1
    c.jal 1f                 # word-aligned c.jal
1:  mv   s1, ra
    c.nop                    # move to a halfword boundary
    c.jal 2f                 # halfword-aligned c.jal
2:  mv   s2, ra
    c.jalr a0                # halfword-aligned c.jalr: ra = pc + 2
    mv   s3, ra
    c.nop
    c.jalr a0                # word-aligned c.jalr
    mv   s4, ra
    .option push
    .option norvc
    jal  ra, 3f              # 32-bit jal for contrast
3:  mv   s5, ra
    .option pop
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
4:  j 4b
f1: c.jr ra
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
