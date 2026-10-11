# Read-after-write chains while every instruction spends extra EX cycles on
# its fetch PMP check: in U-mode, then in M-mode with a locked entry, with
# 32-bit instructions both aligned (one check cycle) and straddling a word
# (two). The instruction in EX must re-present its own registers to the
# synchronous register file on each check cycle, and each instruction reads
# the one before it.
.section .text.init
.option norvc
.option norelax
.globl rvtest_entry_point
rvtest_entry_point:
    la   t0, handler
    csrw mtvec, t0
    li   t0, -1
    csrw pmpaddr0, t0
    li   t0, 0x1f                # entry 0: NAPOT, all of memory, RWX
    csrw pmpcfg0, t0
    la   s0, buf
    li   a0, 3
    li   a1, 5
    li   s11, 0
    li   t1, 0                   # MPP = U
    csrw mstatus, t1
    la   t2, user
    csrw mepc, t2
    mret

.option rvc
    .balign 4
.option norvc
user:
    add  a2, a0, a1              # aligned
    add  a3, a2, a2
    sub  a4, a3, a2
.option rvc
    c.nop
.option norvc
    add  a5, a4, a4              # straddling from here on
    mul  a6, a5, a4
    sw   a6, 0(s0)
    lw   a7, 0(s0)
    add  t3, a7, a6
    beq  t3, t3, 1f
    nop
1:
.option rvc
    c.mv  a0, t3                 # compressed between straddles
    c.add a0, a0
.option norvc
    xor  t4, a0, t3
    ecall                        # back to M

.option rvc
    .balign 4                    # pads with a c.nop if needed
.option norvc
handler:
    addi s11, s11, 1
    csrr t5, mcause
    li   t6, 1
    bne  s11, t6, done
    # M-mode with entry 0 locked: the fetch is checked in M-mode too.
    li   t0, 0x9f                # L | NAPOT | RWX
    csrw pmpcfg0, t0
    add  a2, a0, a1
    add  a3, a2, a2
.option rvc
    c.nop
.option norvc
    sub  a4, a3, a2              # straddling
    or   a5, a4, a4
    lw   a6, 0(s0)
    add  a7, a6, a5
    divu t3, a7, a1
    add  t4, t3, t3
.option rvc
    c.sw  a0, 4(s0)
.option norvc
    lw   s1, 4(s0)
    sub  s2, s1, a0
done:
    li   t6, 1
    la   t5, tohost
    sw   t6, 0(t5)
2:  j 2b

.section .data
.balign 16
buf: .word 0, 0, 0, 0
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
