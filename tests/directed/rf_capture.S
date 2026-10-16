# The register file reads synchronously: the registers of the instruction
# entering EX are taken from the fetched bits on the edge IF/EX takes it,
# while the instruction two ahead, in WB, writes on that same edge. With a
# fast fetch, "writer; filler; reader" puts the write exactly on the reader's
# capture edge (write-first), and "writer; reader" on its forwarding cycle.
# Both are done here for every way an instruction names its registers --
# each 32-bit format, and every compressed form, whose fields rf_fields
# finds without expanding it (sp, rs1'/rs2', full fields) -- reading the
# written register on both ports where the format has two. Then x0: as a
# destination (32-bit and the compressed HINTs), which must leave it 0 on the
# next reads and on the capture edge, and as every kind of source.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    la   s0, buf
    li   s1, 0x11
    li   a0, 0x100
    li   a1, 0x200

    # 32-bit formats: writer; filler; reader (capture edge) and writer; reader
    addi a2, a0, 1
    nop
    add  a3, a2, a2              # R, both ports
    addi a4, a2, 2
    sub  a5, a4, a4              # R, forwarded
    addi a2, a2, 3
    nop
    addi a3, a2, 4               # I
    addi a4, s0, 4
    nop
    sw   a4, 0(a4)               # S: base and data, same register
    addi a5, a4, 0
    nop
    bne  a5, a4, 1f              # B, both ports
    nop
1:  la   a6, 2f
    nop
    jalr a7, 0(a6)               # JALR
2:  addi t0, a7, 1
    nop
    csrrw t1, mscratch, t0       # CSR rs1
    mv   t2, s0
    nop
    lw   t3, 0(t2)               # load base
    addi t4, s0, 8
    nop
    amoswap.w t5, t4, (t4)       # AMO, both ports
    addi t6, s0, 8
    nop
    lr.w a0, (t6)                # LR
    addi a1, t6, 0
    nop
    sc.w a2, a1, (a1)            # SC, both ports

    # Compressed. Each writer is followed by a filler, then the reader.
.option rvc
    addi sp, s0, 16              # sp for the sp-relative forms
    c.nop
    c.addi4spn s1, sp, 8         # reads sp: s1 = buf + 24
    c.addi s1, -8                # rd/rs1 full field (x9), forwarded: buf + 16
    c.nop
    c.lw   a2, 0(s1)             # rs1' (s1 = x9), on the capture edge
    c.nop
    c.sw   a2, 4(s1)             # rs1' and rs2'
    c.nop
    li     a3, 3
    c.nop
    c.slli a3, 2                 # full field
    c.lwsp a3, 4(sp)             # sp
    c.nop
    c.swsp a3, 0(sp)             # sp and rs2 (full)
    c.addi16sp sp, 16            # reads sp
    c.nop
    c.addi16sp sp, -16
    li   a4, 0x7fff
    c.nop
    c.srli a4, 3                 # rs1'
    c.nop
    c.srai a4, 1
    c.nop
    c.andi a4, 0x1f
    li   a5, 0x0f0f
    c.nop
    c.sub  a4, a5                # rs1', rs2'
    c.nop
    c.xor  a5, a4
    c.nop
    c.or   a4, a5
    c.nop
    c.and  a5, a4
    c.nop
    c.mv   a3, a5                # rs2 full
    c.nop
    c.add  a3, a3                # rs1 and rs2 full, the same register
    c.nop
    c.beqz a3, 3f                # rs1'
    c.nop
    c.bnez a3, 3f
    c.nop
3:  la   t0, 4f
    c.nop
    c.jr   t0                    # rs1 full
    c.nop
4:  la   ra, 5f
    c.nop
    c.jalr ra                    # reads x1, writes x1
5:  c.mv   a2, ra
.option norvc

    # x0 as a destination: never written, reads 0 at once and on the edge
    # the write would have landed on.
    add  x0, a0, a1
    add  a3, x0, x0
    nop
    add  a4, x0, x0
    lui  x0, 0x12345
    nop
    or   a5, x0, a4
    .hword 0x4015                # c.li x0, 5 (HINT)
    nop
    add  a6, x0, x0
    .hword 0x802a                # c.mv x0, a0 (HINT)
    nop
    add  a6, a6, x0
    .hword 0x902e                # c.add x0, a1 (HINT)
    nop
    sub  a7, x0, a6
    lw   x0, 0(s0)               # load to x0
    add  t1, x0, x0
    nop
    add  t2, x0, x0
    # x0 as a source in every position
    sw   x0, 4(s0)
    lw   t3, 4(s0)
    beq  x0, x0, 6f
    nop
6:  amoswap.w t4, x0, (s0)
    lw   t5, 0(s0)
    sltu t6, x0, t5
    csrrw t1, mscratch, x0
    csrr  t2, mscratch

    li   s1, 1
    la   s2, tohost
    sw   s1, 0(s2)
8:  j 8b

.section .data
.balign 16
buf: .word 0x55aa55aa, 0x12345678, 0, 0, 0, 0, 0, 0
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
